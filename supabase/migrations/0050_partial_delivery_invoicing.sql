begin;
-- Partial allocations reserve immutable delivery quantities while an invoice is draft or posted.
create table public.goods_delivery_partial_invoices(
 id uuid not null unique default gen_random_uuid(), invoice_id uuid primary key references sales_invoices(id) on delete cascade,
 delivery_id uuid not null references goods_document_drafts(id),
 company_id uuid not null references companies(id),request_id uuid not null unique,
 request_payload jsonb not null,items jsonb not null,allocated_cost numeric(18,2) not null check(allocated_cost>=0),
 created_by uuid not null default auth.uid(),created_at timestamptz not null default now()
);
create index delivery_partial_invoice_source on goods_delivery_partial_invoices(delivery_id);
alter table goods_delivery_partial_invoices enable row level security;
create policy "partial delivery invoicing read" on goods_delivery_partial_invoices for select to authenticated using(has_company_permission(company_id,'sales'));
create trigger delivery_partial_invoice_audit after insert or delete on goods_delivery_partial_invoices for each row execute function write_audit_log();
create function public.guard_delivery_invoicing_mode() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if TG_TABLE_NAME='goods_delivery_invoice_links' then
  if exists(select 1 from goods_delivery_partial_invoices l join sales_invoices b on b.id=l.invoice_id where l.delivery_id=new.delivery_id and b.status<>'void') then raise exception 'Partial billing already reserves this delivery; use its remaining-quantity billing flow';end if;
 else
  if not exists(select 1 from goods_delivery_postings p where p.delivery_id=new.delivery_id and p.company_id=new.company_id and p.status='posted') or exists(select 1 from goods_delivery_invoice_links where delivery_id=new.delivery_id) then raise exception 'Active posted delivery without a full-invoice link required';end if;
 end if;
 return new;
end $$;
create trigger delivery_full_invoicing_mode before insert on goods_delivery_invoice_links for each row execute function guard_delivery_invoicing_mode();
create trigger delivery_partial_invoiceing_mode before insert on goods_delivery_partial_invoices for each row execute function guard_delivery_invoicing_mode();

create function public.get_delivery_invoicing_progress(target_delivery uuid) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare p goods_delivery_postings%rowtype; result jsonb;
begin
 select * into p from goods_delivery_postings where delivery_id=target_delivery;
 if not found or not has_company_permission(p.company_id,'sales') then raise exception 'Posted delivery not found or sales access denied';end if;
 select jsonb_agg(x||jsonb_build_object('reserved_quantity',q.reserved,'remaining_quantity',(x->>'quantity')::numeric-q.reserved) order by ordinal) into result
 from jsonb_array_elements(p.items) with ordinality as source(x,ordinal) cross join lateral(
 select case when exists(select 1 from goods_delivery_invoice_links f join sales_invoices b on b.id=f.invoice_id where f.delivery_id=p.delivery_id and b.status<>'void') then (x->>'quantity')::numeric else
 coalesce((select sum((i->>'quantity')::numeric) from goods_delivery_partial_invoices l join sales_invoices b on b.id=l.invoice_id cross join lateral jsonb_array_elements(l.items) i where l.delivery_id=p.delivery_id and b.status<>'void' and i->>'product_id'=x->>'product_id'),0) end reserved
 ) q;
 return jsonb_build_object('status',p.status,'items',result);
end $$;

create function public.create_partial_delivery_invoice(target_delivery uuid,target_due_date date,prices jsonb,request_id uuid) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare r goods_document_drafts%rowtype; p goods_delivery_postings%rowtype; existing goods_delivery_partial_invoices%rowtype; payload jsonb; result uuid; branch uuid; item jsonb; source jsonb; qty numeric; price numeric; tax numeric; reserved numeric; previous_cost numeric; line_cost numeric(18,2); amount numeric(18,2):=0; snapshot jsonb:='[]';
begin
 select * into r from goods_document_drafts where id=target_delivery for update;
 if not found or r.kind<>'delivery' or not has_company_permission(r.company_id,'sales') then raise exception 'Delivery not found or sales access denied';end if;
 payload:=jsonb_build_object('due_date',target_due_date,'prices',prices);
 if request_id is null then raise exception 'Request identifier required';end if;
 select * into existing from goods_delivery_partial_invoices l where l.request_id=create_partial_delivery_invoice.request_id;
 if found then
  if existing.delivery_id<>r.id or existing.company_id<>r.company_id or existing.request_payload<>payload then raise exception 'Request identifier already used for different invoice data';end if;
  return existing.invoice_id;
 end if;
 select * into p from goods_delivery_postings where delivery_id=r.id for update;
 if not found or p.status<>'posted' then raise exception 'Active posted delivery required';end if;
 if exists(select 1 from goods_delivery_invoice_links where delivery_id=r.id) then raise exception 'Review or replace the existing full delivery invoice first';end if;
 if target_due_date is null or target_due_date<r.document_date then raise exception 'Due date must be on or after delivery date';end if;
 select w.branch_id into branch from warehouses w join branches b on b.id=w.branch_id and b.company_id=w.company_id and b.active where w.id=r.warehouse_id and w.company_id=r.company_id and w.active;
 if branch is null or not exists(select 1 from contacts where id=r.contact_id and company_id=r.company_id and active and kind in ('customer','both')) then raise exception 'Active company warehouse, branch and customer required';end if;
 if prices is null or jsonb_typeof(prices)<>'array' or jsonb_array_length(prices)=0 or exists(select 1 from jsonb_array_elements(prices) x group by x->>'product_id' having count(*)>1) then raise exception 'Select distinct delivery products to invoice';end if;
 for item in select value from jsonb_array_elements(prices) loop
  select value into source from jsonb_array_elements(p.items) where value->>'product_id'=item->>'product_id';
  if source is null then raise exception 'Product is not on this delivery';end if;
  if not exists(select 1 from products where id=(source->>'product_id')::uuid and company_id=r.company_id and active and not is_service) then raise exception 'Invalid delivery product';end if;
  qty:=(item->>'quantity')::numeric;price:=(item->>'unit_price')::numeric;tax:=(item->>'gst_rate')::numeric;
  if qty is null or price is null or tax is null or qty::text in ('NaN','Infinity','-Infinity') or price::text in ('NaN','Infinity','-Infinity') or tax::text in ('NaN','Infinity','-Infinity') or qty<=0 or qty<>round(qty,3) or qty>=1000000000000000 or price<0 or price<>round(price,2) or price>=10000000000000000 or tax<0 or tax>100 or tax<>round(tax,2) then raise exception 'Invalid quantity, price or GST';end if;
  select coalesce(sum((i->>'quantity')::numeric),0),coalesce(sum((i->>'allocated_cost')::numeric),0) into reserved,previous_cost
  from goods_delivery_partial_invoices l join sales_invoices b on b.id=l.invoice_id cross join lateral jsonb_array_elements(l.items) i where l.delivery_id=r.id and b.status<>'void' and i->>'product_id'=source->>'product_id';
  if qty+reserved>(source->>'quantity')::numeric then raise exception 'Quantity exceeds unbilled delivery balance';end if;
  -- Cumulative rounding clears the exact original accrual, including voided allocation holes.
  line_cost:=round((reserved+qty)*(source->>'unit_cost')::numeric,2)-previous_cost;
  if line_cost<0 then raise exception 'Allocation rounding needs a larger quantity or reviewed correction';end if;
  amount:=amount+line_cost;
  snapshot:=snapshot||jsonb_build_array(jsonb_build_object('product_id',source->>'product_id','description',source->>'description','quantity',qty,'allocated_cost',line_cost,'unit_price',price,'gst_rate',tax));
 end loop;
 if (select sum(round((i->>'quantity')::numeric*(i->>'unit_price')::numeric,2)) from jsonb_array_elements(snapshot) i)<=0 then raise exception 'Invoice requires a positive subtotal';end if;
 insert into sales_invoices(company_id,branch_id,warehouse_id,customer_id,invoice_date,due_date,notes,created_by)
 values(r.company_id,branch,r.warehouse_id,r.contact_id,r.document_date,target_due_date,'Partial invoicing of goods delivery DN-'||r.document_number,auth.uid()) returning id into result;
 insert into sales_invoice_lines(invoice_id,product_id,description,quantity,unit_price,gst_rate)
 select result,(i->>'product_id')::uuid,i->>'description',(i->>'quantity')::numeric,(i->>'unit_price')::numeric,(i->>'gst_rate')::numeric from jsonb_array_elements(snapshot) i;
 insert into goods_delivery_partial_invoices(invoice_id,delivery_id,company_id,request_id,request_payload,items,allocated_cost) values(result,r.id,r.company_id,request_id,payload,snapshot,amount);
 return result;
end $$;
revoke all on function get_delivery_invoicing_progress(uuid),create_partial_delivery_invoice(uuid,date,jsonb,uuid) from public,anon;
grant execute on function get_delivery_invoicing_progress(uuid),create_partial_delivery_invoice(uuid,date,jsonb,uuid) to authenticated;
create or replace function public.post_sales_invoice(target_invoice uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare inv sales_invoices%rowtype; sub numeric(18,2); tax numeric(18,2); grand numeric(18,2);
  ar_account uuid; sales_account uuid; gst_account uuid; inventory_account uuid; cogs_account uuid; new_journal uuid; target_warehouse uuid; line record; cogs_total numeric(18,2); dispatch goods_delivery_postings%rowtype; partial_invoice goods_delivery_partial_invoices%rowtype; matching_items jsonb;
begin
  select * into inv from sales_invoices where id=target_invoice and status='draft' for update;
  if inv.id is null or not has_company_permission(inv.company_id,'sales') then raise exception 'Invoice not found or sales access denied'; end if;
  if not exists(select 1 from contacts where id=inv.customer_id and company_id=inv.company_id and kind in ('customer','both') and active) then raise exception 'Invalid customer'; end if;
  if not exists(select 1 from branches where id=inv.branch_id and company_id=inv.company_id and active) then raise exception 'Invalid branch'; end if;
  if exists(select 1 from sales_invoice_lines l join products p on p.id=l.product_id where l.invoice_id=inv.id and p.company_id<>inv.company_id) then raise exception 'Invalid product company'; end if;
  select coalesce(sum(subtotal),0),coalesce(sum(gst_amount),0),coalesce(sum(total),0) into sub,tax,grand from sales_invoice_lines where invoice_id=inv.id;
  if grand<=0 then raise exception 'Invoice requires at least one line'; end if;
  select id into ar_account from accounts where company_id=inv.company_id and code='1100';
  select id into sales_account from accounts where company_id=inv.company_id and code='4000';
  select id into gst_account from accounts where company_id=inv.company_id and code='2100';
  select id into inventory_account from accounts where company_id=inv.company_id and code='1200';
  select id into cogs_account from accounts where company_id=inv.company_id and code='5000';
  select coalesce(sum(l.quantity*p.average_cost),0) into cogs_total from sales_invoice_lines l join products p on p.id=l.product_id where l.invoice_id=inv.id and not p.is_service;
  if ar_account is null or sales_account is null or (tax>0 and gst_account is null) or (cogs_total>0 and (inventory_account is null or cogs_account is null)) then raise exception 'Required system accounts are missing'; end if;
  select * into partial_invoice from goods_delivery_partial_invoices where invoice_id=inv.id;
  if partial_invoice.invoice_id is not null then
    select * into dispatch from goods_delivery_postings where delivery_id=partial_invoice.delivery_id for update;
  else
  select p.* into dispatch from goods_delivery_postings p join goods_delivery_invoice_links l on l.delivery_id=p.delivery_id where l.invoice_id=inv.id for update of p;
  end if;
  if dispatch.id is not null then
    matching_items:=coalesce(partial_invoice.items,dispatch.items);
    if dispatch.status<>'posted' or dispatch.company_id<>inv.company_id or not exists(select 1 from goods_document_drafts d join journal_entries j on j.id=dispatch.journal_entry_id where d.id=dispatch.delivery_id and d.contact_id=inv.customer_id and d.warehouse_id=inv.warehouse_id and d.document_date<=inv.invoice_date and j.branch_id=inv.branch_id) then raise exception 'Linked dispatch does not match invoice';end if;
    if (select count(*) from sales_invoice_lines where invoice_id=inv.id)<>jsonb_array_length(matching_items)
      or exists(select 1 from sales_invoice_lines l where l.invoice_id=inv.id and not exists(select 1 from jsonb_array_elements(matching_items) x where (x->>'product_id')::uuid=l.product_id and (x->>'quantity')::numeric=l.quantity))
      or exists(select 1 from sales_invoice_lines where invoice_id=inv.id group by product_id having count(*)>1) then raise exception 'Delivery invoice must retain its allocated product quantities';end if;
    cogs_total:=coalesce(partial_invoice.allocated_cost,dispatch.total);
    inventory_account:=dispatch.clearing_account_id;
  end if;
  insert into journal_entries(company_id,branch_id,entry_date,reference,description,created_by)
  values(inv.company_id,inv.branch_id,inv.invoice_date,'INV-'||lpad(inv.invoice_number::text,6,'0'),'Sales invoice',auth.uid()) returning id into new_journal;
  insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,ar_account,'Customer receivable',grand,0),(new_journal,sales_account,'Sales revenue',0,sub);
  if tax>0 then insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,gst_account,'Output GST',0,tax); end if;
  if cogs_total>0 then insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,cogs_account,'Cost of goods sold',cogs_total,0),(new_journal,inventory_account,'Inventory issued',0,cogs_total); end if;
  perform set_config('cloudledger.posting_permission','sales',true);
  perform post_journal(new_journal);
  update sales_invoices set subtotal=sub,gst_total=tax,total=grand,status='posted',journal_entry_id=new_journal,posted_at=now() where id=inv.id;
  if exists(select 1 from goods_delivery_invoice_links where invoice_id=inv.id) then
    select w.id into target_warehouse from goods_delivery_invoice_links l join goods_document_drafts d on d.id=l.delivery_id join warehouses w on w.id=d.warehouse_id
    where l.invoice_id=inv.id and l.company_id=inv.company_id and d.company_id=inv.company_id and d.contact_id=inv.customer_id and w.company_id=inv.company_id and w.branch_id=inv.branch_id and w.active and w.id=inv.warehouse_id;
    if target_warehouse is null then raise exception 'Linked delivery customer/branch/warehouse mismatch or inactive warehouse'; end if;
  elsif inv.warehouse_id is not null then
    select id into target_warehouse from warehouses where id=inv.warehouse_id and company_id=inv.company_id and branch_id=inv.branch_id and active;
    if target_warehouse is null then raise exception 'Invalid invoice warehouse'; end if;
  else
    select id into target_warehouse from warehouses where company_id=inv.company_id and branch_id=inv.branch_id and active order by created_at limit 1;
  end if;
  if dispatch.id is null then
  for line in select l.product_id,l.quantity,p.average_cost,p.is_service from sales_invoice_lines l join products p on p.id=l.product_id where l.invoice_id=inv.id and l.product_id is not null loop
    if not line.is_service then
      if target_warehouse is null then raise exception 'Branch warehouse is missing'; end if;
      insert into stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,created_by)
      values(inv.company_id,target_warehouse,line.product_id,'sale',inv.invoice_date,line.quantity,line.average_cost,'sales_invoice',inv.id,auth.uid());
    end if;
  end loop;
  end if;
end; $$;


create or replace view public.sales_dispatch_cost_sources with (security_invoker=true) as
 select company_id,warehouse_id,product_id,movement_type,quantity,unit_cost,source_id from stock_movements where source_type='sales_invoice' and movement_type='sale'
 union all
 select m.company_id,m.warehouse_id,m.product_id,m.movement_type,m.quantity,m.unit_cost,l.invoice_id as source_id
 from stock_movements m join goods_delivery_invoice_links l on l.delivery_id=m.source_id and l.company_id=m.company_id
 join goods_delivery_postings p on p.delivery_id=l.delivery_id and p.status='posted'
 where m.source_type='goods_delivery' and m.movement_type='sale'
 union all
 select l.company_id,d.warehouse_id,(i->>'product_id')::uuid,'sale'::public.stock_movement_type,(i->>'quantity')::numeric(18,3),
 ((i->>'allocated_cost')::numeric/nullif((i->>'quantity')::numeric,0))::numeric(18,2),l.invoice_id
 from goods_delivery_partial_invoices l join goods_delivery_postings p on p.delivery_id=l.delivery_id and p.company_id=l.company_id and p.status='posted'
 join goods_document_drafts d on d.id=l.delivery_id cross join lateral jsonb_array_elements(l.items) i;
revoke all on public.sales_dispatch_cost_sources from public,anon,authenticated;

-- Immutable snapshots make cumulative return cost exact, including voided-return holes.
create table public.partial_delivery_return_costs(
 id uuid not null unique default gen_random_uuid(), credit_note_id uuid primary key references sales_credit_notes(id),invoice_id uuid not null references sales_invoices(id),company_id uuid not null references companies(id),items jsonb not null,
 created_by uuid not null default auth.uid(),created_at timestamptz not null default now()
);
alter table partial_delivery_return_costs enable row level security;
create policy "partial dispatch return costs read" on partial_delivery_return_costs for select to authenticated using(has_company_permission(company_id,'sales'));
create trigger partial_dispatch_return_audit after insert on partial_delivery_return_costs for each row execute function write_audit_log();
create function public.calculate_partial_dispatch_return(target_note uuid) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
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
  if round(row.quantity*round(cost/row.quantity,2),2)<>cost then raise exception 'Return cost cannot be represented at stock precision; a reviewed valuation adjustment is required';end if;
  result:=result||jsonb_build_array(jsonb_build_object('product_id',row.product_id,'quantity',row.quantity,'allocated_cost',cost));
 end loop;
 return result;
end $$;
revoke all on function calculate_partial_dispatch_return(uuid) from public,anon,authenticated;
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
      case when allocated_return is not null then (select (i->>'allocated_cost')::numeric/(i->>'quantity')::numeric from jsonb_array_elements(allocated_return) i where i->>'product_id'=nl.product_id::text) else
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


create or replace function public.reverse_goods_delivery(target_delivery uuid,reason text) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare r goods_document_drafts%rowtype; p goods_delivery_postings%rowtype; item jsonb; result uuid; movement_count bigint;
begin
 select * into r from goods_document_drafts where id=target_delivery for update;
 if not found or not has_company_permission(r.company_id,'sales') or not has_company_permission(r.company_id,'inventory') or not has_company_permission(r.company_id,'accounting') then raise exception 'Access denied';end if;
 select * into p from goods_delivery_postings where delivery_id=r.id for update;
 if not found then raise exception 'Posted delivery not found';end if;if p.status='reversed' then return p.reversal_id;end if;
 if length(trim(coalesce(reason,'')))<3 then raise exception 'Reversal reason required';end if;
 if exists(select 1 from goods_delivery_partial_invoices l join sales_invoices i on i.id=l.invoice_id where l.delivery_id=r.id and i.status<>'void') then raise exception 'Delete or void all allocated invoices before reversing the dispatch';end if;
 if exists(select 1 from goods_delivery_invoice_links l join sales_invoices b on b.id=l.invoice_id where l.delivery_id=r.id and b.status<>'void') then raise exception 'Delete the linked invoice draft or void its posted invoice first';end if;
 perform 1 from products where id in(select (value->>'product_id')::uuid from jsonb_array_elements(p.items)) order by id for update;
 for item in select value from jsonb_array_elements(p.items) loop
  select count(*) into movement_count from stock_movements where company_id=r.company_id and product_id=(item->>'product_id')::uuid;
  if movement_count<>(item->>'previous_count')::bigint+1 then raise exception 'Later stock activity exists; delivery reversal needs a reviewed valuation adjustment';end if;
 end loop;
 for item in select value from jsonb_array_elements(p.items) loop
  insert into stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,reference,created_by) values(r.company_id,r.warehouse_id,(item->>'product_id')::uuid,'return_in',current_date,(item->>'quantity')::numeric,(item->>'unit_cost')::numeric,'goods_delivery_void',r.id,reason,auth.uid());
  perform set_config('cloudledger.allow_stock_quantity','on',true);update products set average_cost=(item->>'previous_average')::numeric where id=(item->>'product_id')::uuid;perform set_config('cloudledger.allow_stock_quantity','',true);
 end loop;
 perform set_config('cloudledger.posting_permission','accounting',true);perform set_config('cloudledger.delivery_reversal_id',r.id::text,true);result:=create_journal_reversal(p.journal_entry_id,reason);perform set_config('cloudledger.delivery_reversal_id','',true);
 update goods_delivery_postings set status='reversed',reversal_id=result where id=p.id;return result;
end $$;
create or replace function public.correct_sales_invoice(target_invoice uuid,target_reason text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare source public.sales_invoices%rowtype; draft_id uuid;
begin
  select * into source from public.sales_invoices where id=target_invoice for update;
  if source.id is null or not public.has_company_permission(source.company_id,'sales') then
    raise exception 'Invoice not found or sales access denied';
  end if;
  if source.status<>'posted' or source.amount_paid>0 then
    raise exception 'Only unpaid posted invoices can be corrected; reverse allocated receipts first';
  end if;
  if length(trim(coalesce(target_reason,'')))<3 then raise exception 'Correction reason is required'; end if;
  if exists(select 1 from goods_delivery_invoice_links l join goods_delivery_postings p on p.delivery_id=l.delivery_id where l.invoice_id=source.id) then raise exception 'Void this invoice and use Replace voided invoice on its delivery; dispatch stock must be preserved';end if;
  if exists(select 1 from goods_delivery_partial_invoices where invoice_id=source.id) then raise exception 'Void the allocated invoice and create its replacement on the delivery';end if;
  perform public.void_sales_invoice(source.id,target_reason);
  insert into public.sales_invoices(company_id,branch_id,warehouse_id,customer_id,invoice_date,due_date,reference,created_by)
  values(source.company_id,source.branch_id,source.warehouse_id,source.customer_id,source.invoice_date,source.due_date,
    'Correction of INV-'||source.invoice_number||': '||target_reason,auth.uid()) returning id into draft_id;
  insert into public.sales_invoice_lines(invoice_id,sales_order_line_id,product_id,description,quantity,unit_price,gst_rate)
  select draft_id,sales_order_line_id,product_id,description,quantity,unit_price,gst_rate
  from public.sales_invoice_lines where invoice_id=source.id;
  return draft_id;
end; $$;


commit;
