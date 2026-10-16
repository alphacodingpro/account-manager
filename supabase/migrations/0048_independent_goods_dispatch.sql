begin;
create table public.goods_delivery_postings(
 id uuid primary key default gen_random_uuid(),delivery_id uuid not null unique references goods_document_drafts(id),company_id uuid not null references companies(id),journal_entry_id uuid not null unique references journal_entries(id),clearing_account_id uuid not null references accounts(id),items jsonb not null,total numeric(18,2) not null check(total>0),status text not null default 'posted' check(status in ('posted','reversed')),reversal_id uuid references journal_entries(id),created_by uuid not null default auth.uid(),created_at timestamptz not null default now()
);
alter table goods_delivery_postings enable row level security;
create policy "posted deliveries read" on goods_delivery_postings for select to authenticated using(has_company_permission(company_id,'sales'));
create trigger costed_delivery_audit after insert or update on goods_delivery_postings for each row execute function write_audit_log();
create function public.guard_costed_delivery() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if TG_TABLE_NAME='goods_document_drafts' then
  if exists(select 1 from goods_delivery_postings where delivery_id=old.id) then raise exception 'Posted delivery is immutable; reverse from its source and create a new draft';end if;return coalesce(new,old);
 end if;
 if exists(select 1 from goods_delivery_postings where delivery_id=new.delivery_id and status<>'posted') then raise exception 'Reversed delivery cannot be invoiced; create a new delivery';end if;return new;
end $$;
create trigger costed_delivery_lock before update or delete on goods_document_drafts for each row execute function guard_costed_delivery();
create trigger costed_delivery_link before insert on goods_delivery_invoice_links for each row execute function guard_costed_delivery();
create function public.post_goods_delivery(target_delivery uuid) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare r goods_document_drafts%rowtype; result uuid; inventory uuid; clearing uuid; branch uuid; item jsonb; cost numeric; amount numeric(18,2):=0; snapshot jsonb:='[]'; previous_qty numeric; previous_average numeric; previous_count bigint; journal uuid;
begin
 select * into r from goods_document_drafts where id=target_delivery for update;
 if not found or r.kind<>'delivery' or not has_company_permission(r.company_id,'sales') or not has_company_permission(r.company_id,'inventory') or not has_company_permission(r.company_id,'accounting') then raise exception 'Sales, inventory and accounting permission required';end if;
 select id into result from goods_delivery_postings where delivery_id=r.id and status='posted';if result is not null then return result;end if;
 if exists(select 1 from goods_delivery_postings where delivery_id=r.id) or exists(select 1 from goods_delivery_invoice_links where delivery_id=r.id) then raise exception 'Delivery already reversed or linked to an invoice';end if;
 if r.document_date>(now() at time zone 'Asia/Karachi')::date then raise exception 'Delivery date cannot be in the future';end if;
 select w.branch_id into branch from warehouses w join branches b on b.id=w.branch_id and b.company_id=w.company_id and b.active where w.id=r.warehouse_id and w.company_id=r.company_id and w.active;
 if branch is null or not exists(select 1 from contacts where id=r.contact_id and company_id=r.company_id and active and kind in ('customer','both')) then raise exception 'Active warehouse, branch and customer required';end if;
 -- Stable product lock order prevents two dispatches taking opposite product locks.
 perform 1 from products where id in(select (value->>'product_id')::uuid from jsonb_array_elements(r.items)) order by id for update;
 for item in select value from jsonb_array_elements(r.items) loop
  select quantity_on_hand,average_cost into previous_qty,previous_average from products where id=(item->>'product_id')::uuid and company_id=r.company_id and active and not is_service;
  if not found then raise exception 'Invalid delivery stock product';end if;
  cost:=previous_average;
  if cost<=0 then raise exception 'Positive inventory average cost required before dispatch';end if;
  select count(*) into previous_count from stock_movements where product_id=(item->>'product_id')::uuid and company_id=r.company_id;
  amount:=amount+round((item->>'quantity')::numeric*cost,2);
  snapshot:=snapshot||jsonb_build_array(item||jsonb_build_object('unit_cost',cost,'previous_qty',previous_qty,'previous_average',previous_average,'previous_count',previous_count));
 end loop;
 if amount<=0 then raise exception 'Delivery valuation must be positive';end if;
 select id into inventory from accounts where company_id=r.company_id and code='1200' and active and type='asset';
 insert into accounts(company_id,code,name,type,system_account) values(r.company_id,'1210','Goods Dispatched Not Invoiced','asset',true) on conflict(company_id,code) do nothing;
 select id into clearing from accounts where company_id=r.company_id and code='1210' and active and type='asset' and system_account and name='Goods Dispatched Not Invoiced';
 if inventory is null or clearing is null then raise exception 'Active Inventory and reserved dispatch clearing account 1210 required; review any existing account-code conflict';end if;
 insert into journal_entries(company_id,branch_id,entry_date,reference,description,created_by) values(r.company_id,branch,r.document_date,'DN-'||r.document_number,'Unbilled goods dispatch',auth.uid()) returning id into journal;
 insert into journal_lines(entry_id,account_id,debit,credit) values(journal,clearing,amount,0),(journal,inventory,0,amount);
 perform set_config('cloudledger.posting_permission','accounting',true);perform post_journal(journal);
 for item in select value from jsonb_array_elements(snapshot) loop
  insert into stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,created_by) values(r.company_id,r.warehouse_id,(item->>'product_id')::uuid,'sale',r.document_date,(item->>'quantity')::numeric,(item->>'unit_cost')::numeric,'goods_delivery',r.id,auth.uid());
 end loop;
 insert into goods_delivery_postings(delivery_id,company_id,journal_entry_id,clearing_account_id,items,total) values(r.id,r.company_id,journal,clearing,snapshot,amount) returning id into result;return result;
end $$;
create function public.reverse_goods_delivery(target_delivery uuid,reason text) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare r goods_document_drafts%rowtype; p goods_delivery_postings%rowtype; item jsonb; result uuid; movement_count bigint;
begin
 select * into r from goods_document_drafts where id=target_delivery for update;
 if not found or not has_company_permission(r.company_id,'sales') or not has_company_permission(r.company_id,'inventory') or not has_company_permission(r.company_id,'accounting') then raise exception 'Access denied';end if;
 select * into p from goods_delivery_postings where delivery_id=r.id for update;
 if not found then raise exception 'Posted delivery not found';end if;if p.status='reversed' then return p.reversal_id;end if;
 if length(trim(coalesce(reason,'')))<3 then raise exception 'Reversal reason required';end if;
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
create function public.guard_delivery_journal_reversal() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if old.status='posted' and new.status='reversed' and exists(select 1 from goods_delivery_postings p where p.journal_entry_id=old.id and (coalesce(current_setting('cloudledger.delivery_reversal_id',true),'')<>p.delivery_id::text or not exists(select 1 from stock_movements m where m.source_type='goods_delivery_void' and m.source_id=p.delivery_id and m.company_id=p.company_id))) then raise exception 'Reverse this entry from its goods delivery to restore stock and valuation';end if;return new;
end $$;
create trigger delivery_journal_reversal before update of status on journal_entries for each row execute function guard_delivery_journal_reversal();
revoke all on function post_goods_delivery(uuid),reverse_goods_delivery(uuid,text) from public,anon;
grant execute on function post_goods_delivery(uuid),reverse_goods_delivery(uuid,text) to authenticated;

create function public.reopen_goods_delivery_invoicing(target_delivery uuid) returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare r goods_document_drafts%rowtype; linked sales_invoices%rowtype;
begin
 select * into r from goods_document_drafts where id=target_delivery for update;
 if not found or not has_company_permission(r.company_id,'sales') then raise exception 'Delivery not found or sales access denied';end if;
 if not exists(select 1 from goods_delivery_postings where delivery_id=r.id and status='posted') then raise exception 'Active posted delivery required';end if;
 select i.* into linked from sales_invoices i join goods_delivery_invoice_links l on l.invoice_id=i.id where l.delivery_id=r.id for update of i;
 if not found then return;end if;
 if linked.status<>'void' then raise exception 'Void the linked invoice before replacement';end if;
 delete from goods_delivery_invoice_links where delivery_id=r.id;
end $$;
revoke all on function reopen_goods_delivery_invoicing(uuid) from public,anon;
grant execute on function reopen_goods_delivery_invoicing(uuid) to authenticated;
create or replace function public.post_sales_invoice(target_invoice uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare inv sales_invoices%rowtype; sub numeric(18,2); tax numeric(18,2); grand numeric(18,2);
  ar_account uuid; sales_account uuid; gst_account uuid; inventory_account uuid; cogs_account uuid; new_journal uuid; target_warehouse uuid; line record; cogs_total numeric(18,2); dispatch goods_delivery_postings%rowtype;
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
  select p.* into dispatch from goods_delivery_postings p join goods_delivery_invoice_links l on l.delivery_id=p.delivery_id where l.invoice_id=inv.id for update of p;
  if found then
    if dispatch.status<>'posted' or dispatch.company_id<>inv.company_id or not exists(select 1 from goods_document_drafts d join journal_entries j on j.id=dispatch.journal_entry_id where d.id=dispatch.delivery_id and d.contact_id=inv.customer_id and d.warehouse_id=inv.warehouse_id and d.document_date<=inv.invoice_date and j.branch_id=inv.branch_id) then raise exception 'Linked dispatch does not match invoice';end if;
    if (select count(*) from sales_invoice_lines where invoice_id=inv.id)<>jsonb_array_length(dispatch.items)
      or exists(select 1 from sales_invoice_lines l where l.invoice_id=inv.id and not exists(select 1 from jsonb_array_elements(dispatch.items) x where (x->>'product_id')::uuid=l.product_id and (x->>'quantity')::numeric=l.quantity))
      or exists(select 1 from sales_invoice_lines where invoice_id=inv.id group by product_id having count(*)>1) then raise exception 'Dispatched delivery requires full original quantities';end if;
    cogs_total:=dispatch.total;
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


create view public.sales_dispatch_cost_sources with (security_invoker=true) as
 select company_id,warehouse_id,product_id,movement_type,quantity,unit_cost,source_id from stock_movements where source_type='sales_invoice' and movement_type='sale'
 union all
 select m.company_id,m.warehouse_id,m.product_id,m.movement_type,m.quantity,m.unit_cost,l.invoice_id as source_id
 from stock_movements m join goods_delivery_invoice_links l on l.delivery_id=m.source_id and l.company_id=m.company_id
 join goods_delivery_postings p on p.delivery_id=l.delivery_id and p.status='posted'
 where m.source_type='goods_delivery' and m.movement_type='sale';
revoke all on public.sales_dispatch_cost_sources from public,anon,authenticated;
create or replace function public.post_sales_credit_note(target_note uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
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
  select coalesce(sum(nl.quantity*coalesce((select sum(m.quantity*m.unit_cost)/nullif(sum(m.quantity),0) from public.sales_dispatch_cost_sources m where m.company_id=n.company_id and m.source_id=n.invoice_id and m.product_id=nl.product_id and m.movement_type='sale'),0)),0)
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
  if (select count(distinct warehouse_id) from sales_dispatch_cost_sources where company_id=n.company_id and source_id=n.invoice_id and movement_type='sale')>1 then raise exception 'Multi-warehouse invoice requires explicit return allocation'; end if;
  select warehouse_id into target_warehouse from sales_dispatch_cost_sources where company_id=n.company_id and source_id=n.invoice_id and movement_type='sale' limit 1;
  if target_warehouse is null then
    select id into target_warehouse from public.warehouses where company_id=n.company_id and branch_id=n.branch_id and active order by created_at limit 1;
  end if;
  for line in select nl.product_id,nl.quantity,p.is_service,
      coalesce((select sum(m.quantity*m.unit_cost)/nullif(sum(m.quantity),0) from public.sales_dispatch_cost_sources m where m.company_id=n.company_id and m.source_id=n.invoice_id and m.product_id=nl.product_id and m.movement_type='sale'),0) unit_cost
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
