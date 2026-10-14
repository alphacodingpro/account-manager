begin;
alter table sales_invoices add column warehouse_id uuid references warehouses(id);
create function public.validate_invoice_warehouse() returns trigger language plpgsql security invoker set search_path=public as $$
begin
 if TG_OP='UPDATE' and new.warehouse_id is not distinct from old.warehouse_id and new.company_id is not distinct from old.company_id and new.branch_id is not distinct from old.branch_id then return new; end if;
 if new.warehouse_id is not null and not exists(select 1 from warehouses where id=new.warehouse_id and company_id=new.company_id and branch_id=new.branch_id and active) then raise exception 'Invalid invoice warehouse'; end if;
 return new;
end $$;
create trigger invoice_warehouse_valid before insert or update on sales_invoices for each row execute function validate_invoice_warehouse();
-- Delivery conversion preserves complete lines; invoice posting alone moves stock.
create table public.goods_delivery_invoice_links (
 delivery_id uuid primary key references goods_document_drafts(id) on delete restrict,
 invoice_id uuid not null unique references sales_invoices(id) on delete cascade,
 company_id uuid not null references companies(id),
 created_by uuid not null default auth.uid() references auth.users(id),
 created_at timestamptz not null default now()
);
alter table goods_delivery_invoice_links enable row level security;
create policy "delivery invoice link read" on goods_delivery_invoice_links for select to authenticated using(has_company_permission(company_id,'sales'));
-- Link writes are exclusively through the validated conversion RPC.
create function public.lock_converted_goods_delivery() returns trigger language plpgsql security invoker set search_path=public as $$
begin
 if exists(select 1 from goods_delivery_invoice_links where delivery_id=old.id) then raise exception 'Converted delivery is read-only; review the linked invoice'; end if;
 return coalesce(new,old);
end $$;
create trigger converted_goods_delivery_lock before update or delete on goods_document_drafts for each row execute function lock_converted_goods_delivery();
create trigger delivery_invoice_link_audit after insert or delete on goods_delivery_invoice_links for each row execute function write_audit_log();
create function public.convert_goods_delivery_to_invoice(target_delivery uuid,target_due_date date,prices jsonb) returns uuid language plpgsql security definer set search_path=public as $$
declare receipt goods_document_drafts%rowtype; result uuid; branch uuid; item jsonb; price jsonb; amount numeric; tax numeric;
begin
 select * into receipt from goods_document_drafts where id=target_delivery for update;
 if not found or receipt.kind<>'delivery' or not has_company_permission(receipt.company_id,'sales') then raise exception 'Delivery not found or sales access denied'; end if;
 select invoice_id into result from goods_delivery_invoice_links where delivery_id=receipt.id;
 if result is not null then return result; end if;
 if target_due_date is null or target_due_date<receipt.document_date then raise exception 'Due date must be on or after delivery date'; end if;
 select w.branch_id into branch from warehouses w join branches b on b.id=w.branch_id and b.company_id=w.company_id and b.active where w.id=receipt.warehouse_id and w.company_id=receipt.company_id and w.active;
 if branch is null then raise exception 'Active company warehouse and branch required'; end if;
 if not exists(select 1 from contacts where id=receipt.contact_id and company_id=receipt.company_id and active and kind in ('customer','both')) then raise exception 'Active customer required'; end if;
 if prices is null or jsonb_typeof(prices)<>'array' or jsonb_array_length(prices)<>jsonb_array_length(receipt.items) then raise exception 'Review price and GST for every goods line'; end if;
 if exists(select 1 from jsonb_array_elements(prices) p group by p->>'product_id' having count(*)>1) then raise exception 'Duplicate price line'; end if;
 insert into sales_invoices(company_id,branch_id,warehouse_id,customer_id,reference,invoice_date,due_date,notes,created_by)
 values(receipt.company_id,branch,receipt.warehouse_id,receipt.contact_id,receipt.reference,receipt.document_date,target_due_date,concat('Delivery draft DN-',receipt.document_number,E'\n',receipt.notes),auth.uid()) returning id into result;
 for item in select value from jsonb_array_elements(receipt.items) loop
  if not exists(select 1 from products where id=(item->>'product_id')::uuid and company_id=receipt.company_id and active and not is_service) then raise exception 'Invalid stock product'; end if;
  select value into price from jsonb_array_elements(prices) where value->>'product_id'=item->>'product_id';
  amount:=(price->>'unit_price')::numeric;tax:=(price->>'gst_rate')::numeric;
  if amount is null or tax is null or amount::text in ('NaN','Infinity','-Infinity') or tax::text in ('NaN','Infinity','-Infinity') or amount<0 or amount>=10000000000000000 or amount<>round(amount,2) or tax<0 or tax>100 or tax<>round(tax,2) then raise exception 'Invalid price or GST'; end if;
  insert into sales_invoice_lines(invoice_id,product_id,description,quantity,unit_price,gst_rate) values(result,(item->>'product_id')::uuid,item->>'description',(item->>'quantity')::numeric,amount,tax);
 end loop;
 insert into goods_delivery_invoice_links(delivery_id,invoice_id,company_id) values(receipt.id,result,receipt.company_id);
 return result;
end $$;
revoke all on function convert_goods_delivery_to_invoice(uuid,date,jsonb) from public,anon;
grant execute on function convert_goods_delivery_to_invoice(uuid,date,jsonb) to authenticated;
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
  for line in select l.product_id,l.quantity,p.average_cost,p.is_service from sales_invoice_lines l join products p on p.id=l.product_id where l.invoice_id=inv.id and l.product_id is not null loop
    if not line.is_service then
      if target_warehouse is null then raise exception 'Branch warehouse is missing'; end if;
      insert into stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,created_by)
      values(inv.company_id,target_warehouse,line.product_id,'sale',inv.invoice_date,line.quantity,line.average_cost,'sales_invoice',inv.id,auth.uid());
    end if;
  end loop;
end; $$;

create or replace function public.post_sales_credit_note(target_note uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare n public.sales_credit_notes%rowtype; sub numeric(18,2); tax numeric(18,2); grand numeric(18,2); cogs numeric(18,2);
  ar uuid; sales uuid; gst uuid; inventory uuid; cogs_account uuid; new_journal uuid; target_warehouse uuid; line record;
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
  select coalesce(sum(nl.quantity*coalesce((select sum(m.quantity*m.unit_cost)/nullif(sum(m.quantity),0) from public.stock_movements m where m.source_type='sales_invoice' and m.source_id=n.invoice_id and m.product_id=nl.product_id and m.movement_type='sale'),0)),0)
    into cogs from public.sales_credit_note_lines nl join public.products p on p.id=nl.product_id where nl.credit_note_id=n.id and not p.is_service;
  if ar is null or sales is null or (tax>0 and gst is null) or (cogs>0 and (inventory is null or cogs_account is null)) then raise exception 'Required system accounts are missing'; end if;
  insert into public.journal_entries(company_id,branch_id,entry_date,reference,description,created_by)
  values(n.company_id,n.branch_id,n.credit_date,'CN-'||lpad(n.credit_number::text,6,'0'),'Sales return: '||n.reason,auth.uid()) returning id into new_journal;
  insert into public.journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,sales,'Sales return',sub,0),(new_journal,ar,'Customer credit',0,grand);
  if tax>0 then insert into public.journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,gst,'Output GST reversal',tax,0); end if;
  if cogs>0 then insert into public.journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,inventory,'Returned inventory',cogs,0),(new_journal,cogs_account,'COGS reversal',0,cogs); end if;
  perform set_config('cloudledger.posting_permission','sales',true);
  perform public.post_journal(new_journal);
  -- Returns go back to the warehouse actually used by the original invoice.
  if (select count(distinct warehouse_id) from stock_movements where company_id=n.company_id and source_type='sales_invoice' and source_id=n.invoice_id and movement_type='sale')>1 then raise exception 'Multi-warehouse invoice requires explicit return allocation'; end if;
  select warehouse_id into target_warehouse from stock_movements where company_id=n.company_id and source_type='sales_invoice' and source_id=n.invoice_id and movement_type='sale' limit 1;
  if target_warehouse is null then
    select id into target_warehouse from public.warehouses where company_id=n.company_id and branch_id=n.branch_id and active order by created_at limit 1;
  end if;
  for line in select nl.product_id,nl.quantity,p.is_service,
      coalesce((select sum(m.quantity*m.unit_cost)/nullif(sum(m.quantity),0) from public.stock_movements m where m.source_type='sales_invoice' and m.source_id=n.invoice_id and m.product_id=nl.product_id and m.movement_type='sale'),0) unit_cost
    from public.sales_credit_note_lines nl join public.products p on p.id=nl.product_id where nl.credit_note_id=n.id loop
    if not line.is_service then
      if target_warehouse is null then raise exception 'Branch warehouse is missing'; end if;
      insert into public.stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,reference,created_by)
      values(n.company_id,target_warehouse,line.product_id,'return_in',n.credit_date,line.quantity,line.unit_cost,'sales_credit_note',n.id,'INV-'||n.invoice_id,auth.uid());
    end if;
  end loop;
  perform set_config('cloudledger.allow_credit_note_transition','on',true);
  update public.sales_credit_notes set subtotal=sub,gst_total=tax,total=grand,status='posted',journal_entry_id=new_journal,posted_at=now() where id=n.id;
  return new_journal;
end; $$;

create or replace function public.correct_sales_invoice(target_invoice uuid,target_reason text)
returns uuid language plpgsql security definer set search_path=public as $$
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
