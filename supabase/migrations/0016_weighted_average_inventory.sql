-- Weighted-average inventory valuation and warehouse-wise stock ledger.
begin;

alter table public.products add column if not exists average_cost numeric(18,4) not null default 0 check(average_cost>=0);
update public.products set average_cost=purchase_price where average_cost=0 and purchase_price>0;

create or replace function public.protect_product_stock_quantity()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.company_id is distinct from old.company_id then raise exception 'Product company cannot be changed'; end if;
  if (new.quantity_on_hand is distinct from old.quantity_on_hand or new.average_cost is distinct from old.average_cost)
     and coalesce(current_setting('cloudledger.allow_stock_quantity',true),'')<>'on' then
    raise exception 'Stock quantity and valuation can only change through a stock movement';
  end if;
  return new;
end; $$;

create or replace function public.apply_stock_movement()
returns trigger language plpgsql security definer set search_path=public as $$
declare multiplier numeric; current_quantity numeric(18,3); current_average numeric(18,4); next_average numeric(18,4); warehouse_quantity numeric(18,3);
begin
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
  if new.movement_type in ('opening','purchase','adjustment_in','return_in') and new.unit_cost>0 then
    next_average:=round(((current_quantity*current_average)+(new.quantity*new.unit_cost))/(current_quantity+new.quantity),4);
  end if;
  perform set_config('cloudledger.allow_stock_quantity','on',true);
  update products set quantity_on_hand=current_quantity+(new.quantity*multiplier),average_cost=next_average where id=new.product_id;
  perform set_config('cloudledger.allow_stock_quantity','',true);
  return new;
end; $$;

create or replace function public.record_stock_adjustment(target_company uuid,target_warehouse uuid,target_product uuid,target_quantity numeric,target_increase boolean,target_reference text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare new_id uuid; current_cost numeric(18,4);
begin
  if not has_company_permission(target_company,'inventory') then raise exception 'Inventory access denied'; end if;
  if target_quantity<=0 then raise exception 'Quantity must be greater than zero'; end if;
  if nullif(trim(target_reference),'') is null then raise exception 'Adjustment reference is required'; end if;
  select average_cost into current_cost from products where id=target_product and company_id=target_company and active and not is_service;
  if current_cost is null then raise exception 'Invalid stock product'; end if;
  insert into stock_movements(company_id,warehouse_id,product_id,movement_type,quantity,unit_cost,reference,created_by)
  values(target_company,target_warehouse,target_product,case when target_increase then 'adjustment_in'::stock_movement_type else 'adjustment_out'::stock_movement_type end,target_quantity,current_cost,trim(target_reference),auth.uid()) returning id into new_id;
  return new_id;
end; $$;

create or replace function public.post_sales_invoice(target_invoice uuid)
returns void language plpgsql security definer set search_path=public as $$
declare inv sales_invoices%rowtype; sub numeric(18,2); tax numeric(18,2); grand numeric(18,2);
  ar_account uuid; sales_account uuid; gst_account uuid; inventory_account uuid; cogs_account uuid; new_journal uuid; target_warehouse uuid; line record; cogs_total numeric(18,2);
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
  insert into journal_entries(company_id,branch_id,entry_date,reference,description,created_by)
  values(inv.company_id,inv.branch_id,inv.invoice_date,'INV-'||lpad(inv.invoice_number::text,6,'0'),'Sales invoice',auth.uid()) returning id into new_journal;
  insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,ar_account,'Customer receivable',grand,0),(new_journal,sales_account,'Sales revenue',0,sub);
  if tax>0 then insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,gst_account,'Output GST',0,tax); end if;
  if cogs_total>0 then insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,cogs_account,'Cost of goods sold',cogs_total,0),(new_journal,inventory_account,'Inventory issued',0,cogs_total); end if;
  perform set_config('cloudledger.posting_permission','sales',true);
  perform post_journal(new_journal);
  update sales_invoices set subtotal=sub,gst_total=tax,total=grand,status='posted',journal_entry_id=new_journal,posted_at=now() where id=inv.id;
  select id into target_warehouse from warehouses where company_id=inv.company_id and branch_id=inv.branch_id and active order by created_at limit 1;
  for line in select l.product_id,l.quantity,p.average_cost,p.is_service from sales_invoice_lines l join products p on p.id=l.product_id where l.invoice_id=inv.id and l.product_id is not null loop
    if not line.is_service then
      if target_warehouse is null then raise exception 'Branch warehouse is missing'; end if;
      insert into stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,created_by)
      values(inv.company_id,target_warehouse,line.product_id,'sale',inv.invoice_date,line.quantity,line.average_cost,'sales_invoice',inv.id,auth.uid());
    end if;
  end loop;
end; $$;

create or replace function public.void_sales_invoice(target_invoice uuid,target_reason text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare inv sales_invoices%rowtype; reversal_id uuid; line record;
begin
  select * into inv from sales_invoices where id=target_invoice and status='posted' for update;
  if inv.id is null or not has_company_permission(inv.company_id,'sales') then raise exception 'Posted invoice not found or sales access denied'; end if;
  if inv.amount_paid>0 then raise exception 'Paid invoice cannot be voided; reverse its receipt first'; end if;
  for line in select warehouse_id,product_id,quantity,unit_cost from stock_movements where company_id=inv.company_id and source_type='sales_invoice' and source_id=inv.id and movement_type='sale' loop
    insert into stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,reference,created_by)
    values(inv.company_id,line.warehouse_id,line.product_id,'return_in',current_date,line.quantity,line.unit_cost,'sales_invoice_void',inv.id,target_reason,auth.uid());
  end loop;
  perform set_config('cloudledger.posting_permission','sales',true);
  reversal_id:=create_journal_reversal(inv.journal_entry_id,target_reason);
  perform set_config('cloudledger.allow_document_void','on',true);
  update sales_invoices set status='void' where id=inv.id;
  return reversal_id;
end; $$;

create or replace function public.get_inventory_stock(target_company uuid,as_of date default current_date)
returns table(warehouse_id uuid,warehouse_name text,product_id uuid,sku text,product_name text,quantity numeric,average_cost numeric,stock_value numeric)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_company_member(target_company) then raise exception 'Access denied'; end if;
  return query
  select w.id,w.name,p.id,p.sku,p.name,
    coalesce(sum(case when m.movement_type in ('opening','purchase','adjustment_in','transfer_in','return_in') then m.quantity else -m.quantity end),0)::numeric,
    p.average_cost::numeric,
    round(coalesce(sum(case when m.movement_type in ('opening','purchase','adjustment_in','transfer_in','return_in') then m.quantity else -m.quantity end),0)*p.average_cost,2)::numeric
  from stock_movements m join warehouses w on w.id=m.warehouse_id join products p on p.id=m.product_id
  where m.company_id=target_company and m.movement_date<=as_of
  group by w.id,w.name,p.id,p.sku,p.name,p.average_cost
  having coalesce(sum(case when m.movement_type in ('opening','purchase','adjustment_in','transfer_in','return_in') then m.quantity else -m.quantity end),0)<>0
  order by w.name,p.name;
end; $$;

revoke all on function public.get_inventory_stock(uuid,date) from public,anon;
grant execute on function public.get_inventory_stock(uuid,date) to authenticated;

commit;
