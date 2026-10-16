begin;
create table public.goods_receipt_postings(
 id uuid primary key default gen_random_uuid(),receipt_id uuid not null unique references goods_document_drafts(id),company_id uuid not null references companies(id),journal_entry_id uuid not null unique references journal_entries(id),clearing_account_id uuid not null references accounts(id),items jsonb not null,total numeric(18,2) not null check(total>0),status text not null default 'posted' check(status in ('posted','reversed')),reversal_id uuid references journal_entries(id),created_by uuid not null default auth.uid(),created_at timestamptz not null default now()
);
alter table goods_receipt_postings enable row level security;
create policy "costed receipts read" on goods_receipt_postings for select to authenticated using(has_company_permission(company_id,'purchases'));
create trigger costed_receipt_audit after insert or update on goods_receipt_postings for each row execute function write_audit_log();
create function public.guard_costed_receipt() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if TG_TABLE_NAME='goods_document_drafts' then
  if exists(select 1 from goods_receipt_postings where receipt_id=old.id) then raise exception 'Costed receipt is immutable; reverse from its source and create a new draft';end if;return coalesce(new,old);
 end if;
 if exists(select 1 from goods_receipt_postings where receipt_id=new.receipt_id and status<>'posted') then raise exception 'Reversed receipt cannot be billed; create a new receipt';end if;return new;
end $$;
create trigger costed_receipt_lock before update or delete on goods_document_drafts for each row execute function guard_costed_receipt();
create trigger costed_receipt_link before insert on goods_receipt_bill_links for each row execute function guard_costed_receipt();
create function public.post_goods_receipt(target_receipt uuid,costs jsonb) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare r goods_document_drafts%rowtype; result uuid; inventory uuid; clearing uuid; branch uuid; item jsonb; cost numeric; amount numeric(18,2):=0; snapshot jsonb:='[]'; previous_qty numeric; previous_average numeric; previous_count bigint; journal uuid;
begin
 select * into r from goods_document_drafts where id=target_receipt for update;
 if not found or r.kind<>'receipt' or not has_company_permission(r.company_id,'purchases') or not has_company_permission(r.company_id,'inventory') or not has_company_permission(r.company_id,'accounting') then raise exception 'Purchase, inventory and accounting permission required';end if;
 select id into result from goods_receipt_postings where receipt_id=r.id and status='posted';if result is not null then return result;end if;
 if exists(select 1 from goods_receipt_postings where receipt_id=r.id) or exists(select 1 from goods_receipt_bill_links where receipt_id=r.id) then raise exception 'Receipt already reversed or linked to a bill';end if;
 if r.document_date>(now() at time zone 'Asia/Karachi')::date then raise exception 'Receipt date cannot be in the future';end if;
 select w.branch_id into branch from warehouses w join branches b on b.id=w.branch_id and b.company_id=w.company_id and b.active where w.id=r.warehouse_id and w.company_id=r.company_id and w.active;
 if branch is null or not exists(select 1 from contacts where id=r.contact_id and company_id=r.company_id and active and kind in ('supplier','both')) then raise exception 'Active warehouse, branch and supplier required';end if;
 if costs is null or jsonb_typeof(costs)<>'array' or jsonb_array_length(costs)<>jsonb_array_length(r.items) or exists(select 1 from jsonb_array_elements(costs) x group by x->>'product_id' having count(*)>1) then raise exception 'Review one unit cost for each goods line';end if;
 -- Stable product lock order prevents two receipts taking opposite product locks.
 perform 1 from products where id in(select (value->>'product_id')::uuid from jsonb_array_elements(r.items)) order by id for update;
 for item in select value from jsonb_array_elements(r.items) loop
  select (value->>'unit_cost')::numeric into cost from jsonb_array_elements(costs) where value->>'product_id'=item->>'product_id';
  if cost is null or cost::text in ('NaN','Infinity','-Infinity') or cost<=0 or cost>=10000000000000000 or cost<>round(cost,2) then raise exception 'Positive unit cost with two decimals required';end if;
  select quantity_on_hand,average_cost into previous_qty,previous_average from products where id=(item->>'product_id')::uuid and company_id=r.company_id and active and not is_service;
  if not found then raise exception 'Invalid receipt stock product';end if;
  select count(*) into previous_count from stock_movements where product_id=(item->>'product_id')::uuid and company_id=r.company_id;
  amount:=amount+round((item->>'quantity')::numeric*cost,2);
  snapshot:=snapshot||jsonb_build_array(item||jsonb_build_object('unit_cost',cost,'previous_qty',previous_qty,'previous_average',previous_average,'previous_count',previous_count));
 end loop;
 if amount<=0 then raise exception 'Receipt valuation must be positive';end if;
 select id into inventory from accounts where company_id=r.company_id and code='1200' and active and type='asset';
 insert into accounts(company_id,code,name,type,system_account) values(r.company_id,'2020','Goods Received Not Invoiced','liability',true) on conflict(company_id,code) do nothing;
 select id into clearing from accounts where company_id=r.company_id and code='2020' and active and type='liability' and system_account and name='Goods Received Not Invoiced';
 if inventory is null or clearing is null then raise exception 'Active Inventory and reserved GRNI account 2020 required; review any existing account-code conflict';end if;
 insert into journal_entries(company_id,branch_id,entry_date,reference,description,created_by) values(r.company_id,branch,r.document_date,'GR-'||r.document_number,'Unbilled goods receipt',auth.uid()) returning id into journal;
 insert into journal_lines(entry_id,account_id,debit,credit) values(journal,inventory,amount,0),(journal,clearing,0,amount);
 perform set_config('cloudledger.posting_permission','accounting',true);perform post_journal(journal);
 for item in select value from jsonb_array_elements(snapshot) loop
  insert into stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,created_by) values(r.company_id,r.warehouse_id,(item->>'product_id')::uuid,'purchase',r.document_date,(item->>'quantity')::numeric,(item->>'unit_cost')::numeric,'goods_receipt',r.id,auth.uid());
 end loop;
 insert into goods_receipt_postings(receipt_id,company_id,journal_entry_id,clearing_account_id,items,total) values(r.id,r.company_id,journal,clearing,snapshot,amount) returning id into result;return result;
end $$;
create function public.reverse_goods_receipt(target_receipt uuid,reason text) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare r goods_document_drafts%rowtype; p goods_receipt_postings%rowtype; item jsonb; result uuid; movement_count bigint;
begin
 select * into r from goods_document_drafts where id=target_receipt for update;
 if not found or not has_company_permission(r.company_id,'purchases') or not has_company_permission(r.company_id,'inventory') or not has_company_permission(r.company_id,'accounting') then raise exception 'Access denied';end if;
 select * into p from goods_receipt_postings where receipt_id=r.id for update;
 if not found then raise exception 'Posted receipt not found';end if;if p.status='reversed' then return p.reversal_id;end if;
 if length(trim(coalesce(reason,'')))<3 then raise exception 'Reversal reason required';end if;
 if exists(select 1 from goods_receipt_bill_links l join purchase_bills b on b.id=l.bill_id where l.receipt_id=r.id and b.status<>'void') then raise exception 'Delete the linked bill draft or void its posted bill first';end if;
 perform 1 from products where id in(select (value->>'product_id')::uuid from jsonb_array_elements(p.items)) order by id for update;
 for item in select value from jsonb_array_elements(p.items) loop
  select count(*) into movement_count from stock_movements where company_id=r.company_id and product_id=(item->>'product_id')::uuid;
  if movement_count<>(item->>'previous_count')::bigint+1 then raise exception 'Later stock activity exists; receipt reversal needs a reviewed valuation adjustment';end if;
 end loop;
 for item in select value from jsonb_array_elements(p.items) loop
  insert into stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,reference,created_by) values(r.company_id,r.warehouse_id,(item->>'product_id')::uuid,'return_out',current_date,(item->>'quantity')::numeric,(item->>'unit_cost')::numeric,'goods_receipt_void',r.id,reason,auth.uid());
  perform set_config('cloudledger.allow_stock_quantity','on',true);update products set average_cost=(item->>'previous_average')::numeric where id=(item->>'product_id')::uuid;perform set_config('cloudledger.allow_stock_quantity','',true);
 end loop;
 perform set_config('cloudledger.posting_permission','accounting',true);perform set_config('cloudledger.receipt_reversal_id',r.id::text,true);result:=create_journal_reversal(p.journal_entry_id,reason);perform set_config('cloudledger.receipt_reversal_id','',true);
 update goods_receipt_postings set status='reversed',reversal_id=result where id=p.id;return result;
end $$;
create function public.guard_receipt_journal_reversal() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if old.status='posted' and new.status='reversed' and exists(select 1 from goods_receipt_postings p where p.journal_entry_id=old.id and (coalesce(current_setting('cloudledger.receipt_reversal_id',true),'')<>p.receipt_id::text or not exists(select 1 from stock_movements m where m.source_type='goods_receipt_void' and m.source_id=p.receipt_id and m.company_id=p.company_id))) then raise exception 'Reverse this entry from its goods receipt to restore stock and valuation';end if;return new;
end $$;
create trigger receipt_journal_reversal before update of status on journal_entries for each row execute function guard_receipt_journal_reversal();
revoke all on function post_goods_receipt(uuid,jsonb),reverse_goods_receipt(uuid,text) from public,anon;
grant execute on function post_goods_receipt(uuid,jsonb),reverse_goods_receipt(uuid,text) to authenticated;
create or replace function public.post_purchase_bill(target_bill uuid)
returns void language plpgsql security definer set search_path=public as $$
declare bill purchase_bills%rowtype; sub numeric(18,2); tax numeric(18,2); grand numeric(18,2);
  ap_account uuid; inventory_account uuid; input_tax_account uuid; new_journal uuid; line record; receipt_post goods_receipt_postings%rowtype;
begin
  select * into bill from purchase_bills where id=target_bill and status='draft' for update;
  if bill.id is null or not has_company_permission(bill.company_id,'purchases') then raise exception 'Bill not found or purchase access denied'; end if;
  if not exists(select 1 from contacts where id=bill.supplier_id and company_id=bill.company_id and kind in ('supplier','both') and active) then raise exception 'Invalid supplier'; end if;
  if not exists(select 1 from branches where id=bill.branch_id and company_id=bill.company_id and active) then raise exception 'Invalid branch'; end if;
  if bill.warehouse_id is not null and not exists(select 1 from warehouses where id=bill.warehouse_id and company_id=bill.company_id and branch_id=bill.branch_id and active) then raise exception 'Invalid warehouse'; end if;
  if exists(select 1 from purchase_bill_lines l join products p on p.id=l.product_id where l.bill_id=bill.id and p.company_id<>bill.company_id) then raise exception 'Invalid product company'; end if;
  if exists(select 1 from purchase_bill_lines l join accounts a on a.id=l.expense_account_id where l.bill_id=bill.id and a.company_id<>bill.company_id) then raise exception 'Invalid expense account'; end if;
  if exists(select 1 from purchase_bill_lines l left join products p on p.id=l.product_id where l.bill_id=bill.id and (l.product_id is null or p.is_service) and l.expense_account_id is null) then raise exception 'Expense account is required for non-stock lines'; end if;
  if exists(select 1 from purchase_bill_lines l join products p on p.id=l.product_id where l.bill_id=bill.id and not p.is_service) and bill.warehouse_id is null then raise exception 'Warehouse is required for stock purchases'; end if;
  select coalesce(sum(subtotal),0),coalesce(sum(gst_amount),0),coalesce(sum(total),0) into sub,tax,grand from purchase_bill_lines where bill_id=bill.id;
  if grand<=0 then raise exception 'Bill requires at least one line'; end if;
  select id into ap_account from accounts where company_id=bill.company_id and code='2000';
  select id into inventory_account from accounts where company_id=bill.company_id and code='1200';
  select id into input_tax_account from accounts where company_id=bill.company_id and code='1150';
  if ap_account is null or inventory_account is null or (tax>0 and input_tax_account is null) then raise exception 'Required system accounts are missing'; end if;
  select p.* into receipt_post from goods_receipt_postings p join goods_receipt_bill_links l on l.receipt_id=p.receipt_id where l.bill_id=bill.id for update of p;
  if found then
    if receipt_post.status<>'posted' or receipt_post.company_id<>bill.company_id or not exists(select 1 from goods_document_drafts d where d.id=receipt_post.receipt_id and d.warehouse_id=bill.warehouse_id and d.contact_id=bill.supplier_id and d.document_date<=bill.bill_date and exists(select 1 from journal_entries j where j.id=receipt_post.journal_entry_id and j.branch_id=bill.branch_id)) then raise exception 'Linked receipt does not match this bill';end if;
    if (select count(*) from purchase_bill_lines where bill_id=bill.id)<>jsonb_array_length(receipt_post.items) or exists(select 1 from purchase_bill_lines l where l.bill_id=bill.id and (l.expense_account_id is not null or not exists(select 1 from jsonb_array_elements(receipt_post.items) x where (x->>'product_id')::uuid=l.product_id and (x->>'quantity')::numeric=l.quantity and (x->>'unit_cost')::numeric=l.unit_price))) or exists(select 1 from purchase_bill_lines where bill_id=bill.id group by product_id having count(*)>1) or sub<>receipt_post.total then raise exception 'Costed receipt requires full quantities and matching unit costs; partial matching and price variance need review';end if;
    inventory_account:=receipt_post.clearing_account_id;
  end if;
  insert into journal_entries(company_id,branch_id,entry_date,reference,description,created_by)
  values(bill.company_id,bill.branch_id,bill.bill_date,'BILL-'||lpad(bill.bill_number::text,6,'0'),'Supplier bill',auth.uid()) returning id into new_journal;
  insert into journal_lines(entry_id,account_id,description,debit,credit)
  select new_journal,coalesce(l.expense_account_id,inventory_account),l.description,sum(l.subtotal),0 from purchase_bill_lines l where l.bill_id=bill.id group by coalesce(l.expense_account_id,inventory_account),l.description;
  if tax>0 then insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,input_tax_account,'Input GST',tax,0); end if;
  insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,ap_account,'Supplier payable',0,grand);
  perform set_config('cloudledger.posting_permission','purchases',true);
  perform post_journal(new_journal);
  update purchase_bills set subtotal=sub,gst_total=tax,total=grand,status='posted',journal_entry_id=new_journal,posted_at=now() where id=bill.id;
  if bill.warehouse_id is not null and receipt_post.id is null then
    for line in select l.product_id,l.quantity,l.unit_price from purchase_bill_lines l join products p on p.id=l.product_id where l.bill_id=bill.id and not p.is_service loop
      insert into stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,created_by)
      values(bill.company_id,bill.warehouse_id,line.product_id,'purchase',bill.bill_date,line.quantity,line.unit_price,'purchase_bill',bill.id,auth.uid());
    end loop;
  end if;
end; $$;

create or replace function public.void_purchase_bill(target_bill uuid,target_reason text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare bill purchase_bills%rowtype; reversal_id uuid; line record; receipt_post goods_receipt_postings%rowtype;
begin
  select * into bill from purchase_bills where id=target_bill and status='posted' for update;
  if bill.id is null or not has_company_permission(bill.company_id,'purchases') then raise exception 'Posted bill not found or purchase access denied'; end if;
  if bill.amount_paid>0 then raise exception 'Paid bill cannot be voided; reverse its payment first'; end if;
  select p.* into receipt_post from goods_receipt_postings p join goods_receipt_bill_links l on l.receipt_id=p.receipt_id where l.bill_id=bill.id for update of p;
  if receipt_post.id is null then
  for line in select l.product_id,l.quantity,l.unit_price from purchase_bill_lines l join products p on p.id=l.product_id where l.bill_id=bill.id and not p.is_service loop
    insert into stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,reference,created_by)
    values(bill.company_id,bill.warehouse_id,line.product_id,'return_out',current_date,line.quantity,line.unit_price,'purchase_bill_void',bill.id,target_reason,auth.uid());
  end loop;
  elsif receipt_post.status<>'posted' then raise exception 'Receipt is not posted; review source history';end if;
  perform set_config('cloudledger.posting_permission','purchases',true);
  reversal_id:=create_journal_reversal(bill.journal_entry_id,target_reason);
  perform set_config('cloudledger.allow_document_void','on',true);
  update purchase_bills set status='void' where id=bill.id;
  return reversal_id;
end; $$;

create function public.reopen_goods_receipt_billing(target_receipt uuid) returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare r goods_document_drafts%rowtype; bill_status text;
begin
 select * into r from goods_document_drafts where id=target_receipt for update;
 if not found or not has_company_permission(r.company_id,'purchases') then raise exception 'Purchase access denied';end if;
 if not exists(select 1 from goods_receipt_postings where receipt_id=r.id and status='posted') then raise exception 'Active posted receipt required';end if;
 select b.status::text into bill_status from goods_receipt_bill_links l join purchase_bills b on b.id=l.bill_id where l.receipt_id=r.id for update of b;
 if not found then return;end if;
 if bill_status<>'void' then raise exception 'Void the linked bill before creating a replacement';end if;
 delete from goods_receipt_bill_links where receipt_id=r.id;
end $$;
revoke all on function reopen_goods_receipt_billing(uuid) from public,anon;
grant execute on function reopen_goods_receipt_billing(uuid) to authenticated;
commit;
