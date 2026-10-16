begin;
-- Widen storage only: preserve every existing posted movement value.
-- Rebuild the private dependent view atomically, without CASCADE or client grants.
drop view public.sales_dispatch_cost_sources;
alter table public.stock_movements alter column unit_cost type numeric(38,18);
create view public.sales_dispatch_cost_sources with (security_invoker=true) as
 select company_id,warehouse_id,product_id,movement_type,quantity,unit_cost,source_id from stock_movements where source_type='sales_invoice' and movement_type='sale'
 union all
 select m.company_id,m.warehouse_id,m.product_id,m.movement_type,m.quantity,m.unit_cost,l.invoice_id as source_id
 from stock_movements m join goods_delivery_invoice_links l on l.delivery_id=m.source_id and l.company_id=m.company_id
 join goods_delivery_postings p on p.delivery_id=l.delivery_id and p.status='posted'
 where m.source_type='goods_delivery' and m.movement_type='sale'
 union all
 select l.company_id,d.warehouse_id,(i->>'product_id')::uuid,'sale'::public.stock_movement_type,(i->>'quantity')::numeric(18,3),
 ((i->>'allocated_cost')::numeric(38,18)/nullif((i->>'quantity')::numeric,0))::numeric(38,18),l.invoice_id
 from goods_delivery_partial_invoices l join goods_delivery_postings p on p.delivery_id=l.delivery_id and p.company_id=l.company_id and p.status='posted'
 join goods_document_drafts d on d.id=l.delivery_id cross join lateral jsonb_array_elements(l.items) i;
revoke all on public.sales_dispatch_cost_sources from public,anon,authenticated;

create or replace function public.calculate_partial_dispatch_return(target_note uuid) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare n sales_credit_notes%rowtype; allocation goods_delivery_partial_invoices%rowtype; row record; source jsonb; previous_qty numeric; previous_cost numeric; cost numeric(18,2); result jsonb:='[]';
begin
 select * into n from sales_credit_notes where id=target_note;
 select * into allocation from goods_delivery_partial_invoices where invoice_id=n.invoice_id;
 if not found then return null;end if;
 for row in select product_id,sum(quantity) quantity from sales_credit_note_lines where credit_note_id=n.id group by product_id loop
  select value into source from jsonb_array_elements(allocation.items) where value->>'product_id'=row.product_id::text;
  if source is null then raise exception 'Returned product is not allocated to this delivery invoice';end if;
  select coalesce(sum((i->>'quantity')::numeric),0),coalesce(sum((i->>'allocated_cost')::numeric),0) into previous_qty,previous_cost
  from partial_delivery_return_costs r join sales_credit_notes h on h.id=r.credit_note_id cross join lateral jsonb_array_elements(r.items) i
  where r.invoice_id=n.invoice_id and h.status='posted' and i->>'product_id'=row.product_id::text;
  if previous_qty+row.quantity>(source->>'quantity')::numeric then raise exception 'Return exceeds allocated invoice quantity';end if;
  cost:=round((previous_qty+row.quantity)/(source->>'quantity')::numeric*(source->>'allocated_cost')::numeric,2)-previous_cost;
  if cost<0 then raise exception 'Return rounding needs a larger quantity or reviewed correction';end if;
  if round(row.quantity*round(cost::numeric(38,18)/row.quantity,18),2)<>cost then raise exception 'Return cost exceeds supported stock precision; a reviewed valuation adjustment is required';end if;
  result:=result||jsonb_build_array(jsonb_build_object('product_id',row.product_id,'quantity',row.quantity,'allocated_cost',cost));
 end loop;
 return result;
end $$;
revoke all on function calculate_partial_dispatch_return(uuid) from public,anon,authenticated;
create or replace function public.apply_stock_movement()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare multiplier numeric; current_quantity numeric(18,3); current_average numeric(18,4); next_average numeric(18,4); warehouse_quantity numeric(18,3); remaining_value numeric;
begin
  if new.quantity is null or new.unit_cost is null or new.quantity::text in ('NaN','Infinity','-Infinity') or new.unit_cost::text in ('NaN','Infinity','-Infinity') or new.quantity<=0 or new.unit_cost<0 then raise exception 'Finite positive quantity and nonnegative unit cost required';end if;
  if not exists(select 1 from warehouses w where w.id=new.warehouse_id and w.company_id=new.company_id and w.active) then raise exception 'Warehouse does not belong to company or is inactive'; end if;
  select quantity_on_hand,average_cost into current_quantity,current_average from products
    where id=new.product_id and company_id=new.company_id and active and not is_service for update;
  if current_quantity is null then raise exception 'Invalid stock product'; end if;
  multiplier:=case when new.movement_type in ('opening','purchase','adjustment_in','transfer_in','return_in') then 1 else -1 end;
  if multiplier<0 and current_quantity<new.quantity then raise exception 'Insufficient stock'; end if;
  if multiplier<0 then
    select coalesce(sum(case when movement_type in ('opening','purchase','adjustment_in','transfer_in','return_in') then quantity else -quantity end),0)
      into warehouse_quantity from stock_movements where warehouse_id=new.warehouse_id and product_id=new.product_id;
    if warehouse_quantity<0 then raise exception 'Insufficient stock in selected warehouse'; end if;
  end if;
  next_average:=current_average;
  if new.movement_type in ('opening','purchase','adjustment_in','return_in') and new.unit_cost>=0 then
    next_average:=round(((current_quantity*current_average)+(new.quantity*new.unit_cost))/(current_quantity+new.quantity),4);
  end if;
  -- A credit-note void removes its original returned value, not an unrelated blended cost.
  if new.movement_type='return_out' and new.source_type='sales_credit_note_void' then
    remaining_value:=round(current_quantity*current_average,2)-round(new.quantity*new.unit_cost,2);
    if remaining_value<0 or (current_quantity=new.quantity and remaining_value<>0) then
      raise exception 'Later stock valuation cannot absorb this return reversal; a reviewed valuation adjustment is required';
    end if;
    next_average:=case when current_quantity=new.quantity then 0 else round(remaining_value/(current_quantity-new.quantity),4) end;
  end if;
  perform set_config('cloudledger.allow_stock_quantity','on',true);
  update products set quantity_on_hand=current_quantity+(new.quantity*multiplier),average_cost=next_average where id=new.product_id;
  perform set_config('cloudledger.allow_stock_quantity','',true);
  return new;
end; $$;


create or replace function public.post_sales_credit_note(target_note uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare n public.sales_credit_notes%rowtype; sub numeric(18,2); tax numeric(18,2); grand numeric(18,2); cogs numeric(18,2);
  ar uuid; sales uuid; gst uuid; inventory uuid; cogs_account uuid; new_journal uuid; target_warehouse uuid; line record; allocated_return jsonb;
begin
  select * into n from public.sales_credit_notes where id=target_note and status='draft' for update;
  if n.id is null or not public.has_company_permission(n.company_id,'sales') then raise exception 'Credit-note draft not found or sales access denied'; end if;
  perform 1 from public.sales_invoice_lines where invoice_id=n.invoice_id for update;
  if exists(select 1 from public.sales_credit_note_lines nl join public.sales_invoice_return_progress p on p.invoice_line_id=nl.invoice_line_id
    where nl.credit_note_id=n.id and p.returned_quantity>p.sold_quantity) then raise exception 'Returned quantity exceeds the original invoice'; end if;
  select coalesce(sum(subtotal),0),coalesce(sum(gst_amount),0),coalesce(sum(total),0) into sub,tax,grand from public.sales_credit_note_lines where credit_note_id=n.id;
  if grand<=0 then raise exception 'Credit note requires at least one positive line'; end if;
  select id into ar from public.accounts where company_id=n.company_id and code='1100';
  select id into sales from public.accounts where company_id=n.company_id and code='4000';
  select id into gst from public.accounts where company_id=n.company_id and code='2100';
  select id into inventory from public.accounts where company_id=n.company_id and code='1200';
  select id into cogs_account from public.accounts where company_id=n.company_id and code='5000';
  select coalesce(sum(nl.quantity*coalesce((select sum(m.quantity*m.unit_cost)/nullif(sum(m.quantity),0) from public.sales_dispatch_cost_sources m where m.company_id=n.company_id and m.source_id=n.invoice_id and m.product_id=nl.product_id and m.movement_type='sale'),0)),0)
    into cogs from public.sales_credit_note_lines nl join public.products p on p.id=nl.product_id where nl.credit_note_id=n.id and not p.is_service;
  allocated_return:=calculate_partial_dispatch_return(n.id);
  if allocated_return is not null then select sum((i->>'allocated_cost')::numeric) into cogs from jsonb_array_elements(allocated_return) i;end if;
  if ar is null or sales is null or (tax>0 and gst is null) or (cogs>0 and (inventory is null or cogs_account is null)) then raise exception 'Required system accounts are missing'; end if;
  insert into public.journal_entries(company_id,branch_id,entry_date,reference,description,created_by)
  values(n.company_id,n.branch_id,n.credit_date,'CN-'||lpad(n.credit_number::text,6,'0'),'Sales return: '||n.reason,auth.uid()) returning id into new_journal;
  insert into public.journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,sales,'Sales return',sub,0),(new_journal,ar,'Customer credit',0,grand);
  if tax>0 then insert into public.journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,gst,'Output GST reversal',tax,0); end if;
  if cogs>0 then insert into public.journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,inventory,'Returned inventory',cogs,0),(new_journal,cogs_account,'COGS reversal',0,cogs); end if;
  perform set_config('cloudledger.posting_permission','sales',true);
  perform public.post_journal(new_journal);
  -- Returns go back to the warehouse actually used by the original invoice.
  if (select count(distinct warehouse_id) from sales_dispatch_cost_sources where company_id=n.company_id and source_id=n.invoice_id and movement_type='sale')>1 then raise exception 'Multi-warehouse invoice requires explicit return allocation'; end if;
  select warehouse_id into target_warehouse from sales_dispatch_cost_sources where company_id=n.company_id and source_id=n.invoice_id and movement_type='sale' limit 1;
  if target_warehouse is null then
    select id into target_warehouse from public.warehouses where company_id=n.company_id and branch_id=n.branch_id and active order by created_at limit 1;
  end if;
  for line in select nl.product_id,nl.quantity,p.is_service,
      case when allocated_return is not null then (select (i->>'allocated_cost')::numeric(38,18)/(i->>'quantity')::numeric from jsonb_array_elements(allocated_return) i where i->>'product_id'=nl.product_id::text) else
      coalesce((select sum(m.quantity*m.unit_cost)/nullif(sum(m.quantity),0) from public.sales_dispatch_cost_sources m where m.company_id=n.company_id and m.source_id=n.invoice_id and m.product_id=nl.product_id and m.movement_type='sale'),0) end unit_cost
    from public.sales_credit_note_lines nl join public.products p on p.id=nl.product_id where nl.credit_note_id=n.id loop
    if not line.is_service then
      if target_warehouse is null then raise exception 'Branch warehouse is missing'; end if;
      insert into public.stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,reference,created_by)
      values(n.company_id,target_warehouse,line.product_id,'return_in',n.credit_date,line.quantity,line.unit_cost,'sales_credit_note',n.id,'INV-'||n.invoice_id,auth.uid());
    end if;
  end loop;
  if allocated_return is not null then insert into partial_delivery_return_costs(credit_note_id,invoice_id,company_id,items) values(n.id,n.invoice_id,n.company_id,allocated_return);end if;
  perform set_config('cloudledger.allow_credit_note_transition','on',true);
  update public.sales_credit_notes set subtotal=sub,gst_total=tax,total=grand,status='posted',journal_entry_id=new_journal,posted_at=now() where id=n.id;
  return new_journal;
end; $$;



commit;
