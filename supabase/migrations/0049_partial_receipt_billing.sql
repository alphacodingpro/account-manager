begin;
-- Partial allocations reserve immutable receipt quantities while a bill is draft or posted.
create table public.goods_receipt_partial_bills(
 bill_id uuid primary key references purchase_bills(id) on delete cascade,
 receipt_id uuid not null references goods_document_drafts(id),
 company_id uuid not null references companies(id),request_id uuid not null unique,
 request_payload jsonb not null,items jsonb not null,allocated_cost numeric(18,2) not null check(allocated_cost>=0),
 created_by uuid not null default auth.uid(),created_at timestamptz not null default now()
);
create index receipt_partial_bill_source on goods_receipt_partial_bills(receipt_id);
alter table goods_receipt_partial_bills enable row level security;
create policy "partial receipt billing read" on goods_receipt_partial_bills for select to authenticated using(has_company_permission(company_id,'purchases'));
create trigger receipt_partial_bill_audit after insert or delete on goods_receipt_partial_bills for each row execute function write_audit_log();
create function public.guard_receipt_billing_mode() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if TG_TABLE_NAME='goods_receipt_bill_links' then
  if exists(select 1 from goods_receipt_partial_bills l join purchase_bills b on b.id=l.bill_id where l.receipt_id=new.receipt_id and b.status<>'void') then raise exception 'Partial billing already reserves this receipt; use its remaining-quantity billing flow';end if;
 else
  if not exists(select 1 from goods_receipt_postings p where p.receipt_id=new.receipt_id and p.company_id=new.company_id and p.status='posted') or exists(select 1 from goods_receipt_bill_links where receipt_id=new.receipt_id) then raise exception 'Active posted receipt without a full-bill link required';end if;
 end if;
 return new;
end $$;
create trigger receipt_full_billing_mode before insert on goods_receipt_bill_links for each row execute function guard_receipt_billing_mode();
create trigger receipt_partial_billing_mode before insert on goods_receipt_partial_bills for each row execute function guard_receipt_billing_mode();

create function public.get_receipt_billing_progress(target_receipt uuid) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare p goods_receipt_postings%rowtype; result jsonb;
begin
 select * into p from goods_receipt_postings where receipt_id=target_receipt;
 if not found or not has_company_permission(p.company_id,'purchases') then raise exception 'Posted receipt not found or purchase access denied';end if;
 select jsonb_agg(x||jsonb_build_object('reserved_quantity',q.reserved,'remaining_quantity',(x->>'quantity')::numeric-q.reserved) order by ordinal) into result
 from jsonb_array_elements(p.items) with ordinality as source(x,ordinal) cross join lateral(
 select case when exists(select 1 from goods_receipt_bill_links f join purchase_bills b on b.id=f.bill_id where f.receipt_id=p.receipt_id and b.status<>'void') then (x->>'quantity')::numeric else
 coalesce((select sum((i->>'quantity')::numeric) from goods_receipt_partial_bills l join purchase_bills b on b.id=l.bill_id cross join lateral jsonb_array_elements(l.items) i where l.receipt_id=p.receipt_id and b.status<>'void' and i->>'product_id'=x->>'product_id'),0) end reserved
 ) q;
 return jsonb_build_object('status',p.status,'items',result);
end $$;

create function public.create_partial_receipt_bill(target_receipt uuid,target_due_date date,prices jsonb,request_id uuid) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare r goods_document_drafts%rowtype; p goods_receipt_postings%rowtype; existing goods_receipt_partial_bills%rowtype; payload jsonb; result uuid; branch uuid; item jsonb; source jsonb; qty numeric; price numeric; tax numeric; reserved numeric; previous_cost numeric; line_cost numeric(18,2); amount numeric(18,2):=0; snapshot jsonb:='[]';
begin
 select * into r from goods_document_drafts where id=target_receipt for update;
 if not found or r.kind<>'receipt' or not has_company_permission(r.company_id,'purchases') then raise exception 'Receipt not found or purchase access denied';end if;
 payload:=jsonb_build_object('due_date',target_due_date,'prices',prices);
 if request_id is null then raise exception 'Request identifier required';end if;
 select * into existing from goods_receipt_partial_bills l where l.request_id=create_partial_receipt_bill.request_id;
 if found then
  if existing.receipt_id<>r.id or existing.company_id<>r.company_id or existing.request_payload<>payload then raise exception 'Request identifier already used for different bill data';end if;
  return existing.bill_id;
 end if;
 select * into p from goods_receipt_postings where receipt_id=r.id for update;
 if not found or p.status<>'posted' then raise exception 'Active posted receipt required';end if;
 if exists(select 1 from goods_receipt_bill_links where receipt_id=r.id) then raise exception 'Review or replace the existing full receipt bill first';end if;
 if target_due_date is null or target_due_date<r.document_date then raise exception 'Due date must be on or after receipt date';end if;
 select w.branch_id into branch from warehouses w join branches b on b.id=w.branch_id and b.company_id=w.company_id and b.active where w.id=r.warehouse_id and w.company_id=r.company_id and w.active;
 if branch is null or not exists(select 1 from contacts where id=r.contact_id and company_id=r.company_id and active and kind in ('supplier','both')) then raise exception 'Active company warehouse, branch and supplier required';end if;
 if prices is null or jsonb_typeof(prices)<>'array' or jsonb_array_length(prices)=0 or exists(select 1 from jsonb_array_elements(prices) x group by x->>'product_id' having count(*)>1) then raise exception 'Select distinct receipt products to bill';end if;
 for item in select value from jsonb_array_elements(prices) loop
  select value into source from jsonb_array_elements(p.items) where value->>'product_id'=item->>'product_id';
  if source is null then raise exception 'Product is not on this receipt';end if;
  if not exists(select 1 from products where id=(source->>'product_id')::uuid and company_id=r.company_id and active and not is_service) then raise exception 'Invalid receipt product';end if;
  qty:=(item->>'quantity')::numeric;price:=(item->>'unit_price')::numeric;tax:=(item->>'gst_rate')::numeric;
  if qty is null or price is null or tax is null or qty::text in ('NaN','Infinity','-Infinity') or price::text in ('NaN','Infinity','-Infinity') or tax::text in ('NaN','Infinity','-Infinity') or qty<=0 or qty<>round(qty,3) or qty>=1000000000000000 or price<0 or price<>round(price,2) or price>=10000000000000000 or tax<0 or tax>100 or tax<>round(tax,2) then raise exception 'Invalid quantity, price or GST';end if;
  select coalesce(sum((i->>'quantity')::numeric),0),coalesce(sum((i->>'allocated_cost')::numeric),0) into reserved,previous_cost
  from goods_receipt_partial_bills l join purchase_bills b on b.id=l.bill_id cross join lateral jsonb_array_elements(l.items) i where l.receipt_id=r.id and b.status<>'void' and i->>'product_id'=source->>'product_id';
  if qty+reserved>(source->>'quantity')::numeric then raise exception 'Quantity exceeds unbilled receipt balance';end if;
  -- Cumulative rounding clears the exact original accrual, including voided allocation holes.
  line_cost:=round((reserved+qty)*(source->>'unit_cost')::numeric,2)-previous_cost;
  if line_cost<0 then raise exception 'Allocation rounding needs a larger quantity or reviewed correction';end if;
  amount:=amount+line_cost;
  snapshot:=snapshot||jsonb_build_array(jsonb_build_object('product_id',source->>'product_id','description',source->>'description','quantity',qty,'allocated_cost',line_cost,'unit_price',price,'gst_rate',tax));
 end loop;
 if (select sum(round((i->>'quantity')::numeric*(i->>'unit_price')::numeric,2)) from jsonb_array_elements(snapshot) i)<=0 then raise exception 'Bill requires a positive subtotal';end if;
 insert into purchase_bills(company_id,branch_id,warehouse_id,supplier_id,bill_date,due_date,notes,created_by)
 values(r.company_id,branch,r.warehouse_id,r.contact_id,r.document_date,target_due_date,'Partial billing of goods receipt GR-'||r.document_number,auth.uid()) returning id into result;
 insert into purchase_bill_lines(bill_id,product_id,description,quantity,unit_price,gst_rate)
 select result,(i->>'product_id')::uuid,i->>'description',(i->>'quantity')::numeric,(i->>'unit_price')::numeric,(i->>'gst_rate')::numeric from jsonb_array_elements(snapshot) i;
 insert into goods_receipt_partial_bills(bill_id,receipt_id,company_id,request_id,request_payload,items,allocated_cost) values(result,r.id,r.company_id,request_id,payload,snapshot,amount);
 return result;
end $$;
revoke all on function get_receipt_billing_progress(uuid),create_partial_receipt_bill(uuid,date,jsonb,uuid) from public,anon;
grant execute on function get_receipt_billing_progress(uuid),create_partial_receipt_bill(uuid,date,jsonb,uuid) to authenticated;
create or replace function public.post_purchase_bill(target_bill uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare bill purchase_bills%rowtype; sub numeric(18,2); tax numeric(18,2); grand numeric(18,2);
  ap_account uuid; inventory_account uuid; input_tax_account uuid; new_journal uuid; line record; receipt_post goods_receipt_postings%rowtype; price_variance numeric(18,2); variance_account uuid; partial_bill goods_receipt_partial_bills%rowtype; matching_items jsonb; clearing_cost numeric(18,2);
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
  select * into partial_bill from goods_receipt_partial_bills where bill_id=bill.id;
  if partial_bill.bill_id is not null then
    select * into receipt_post from goods_receipt_postings where receipt_id=partial_bill.receipt_id for update;
  else
  select p.* into receipt_post from goods_receipt_postings p join goods_receipt_bill_links l on l.receipt_id=p.receipt_id where l.bill_id=bill.id for update of p;
  end if;
  if receipt_post.id is not null then
    matching_items:=coalesce(partial_bill.items,receipt_post.items);clearing_cost:=coalesce(partial_bill.allocated_cost,receipt_post.total);
    if receipt_post.status<>'posted' or receipt_post.company_id<>bill.company_id or not exists(select 1 from goods_document_drafts d where d.id=receipt_post.receipt_id and d.warehouse_id=bill.warehouse_id and d.contact_id=bill.supplier_id and d.document_date<=bill.bill_date and exists(select 1 from journal_entries j where j.id=receipt_post.journal_entry_id and j.branch_id=bill.branch_id)) then raise exception 'Linked receipt does not match this bill';end if;
    if (select count(*) from purchase_bill_lines where bill_id=bill.id)<>jsonb_array_length(matching_items) or exists(select 1 from purchase_bill_lines l where l.bill_id=bill.id and (l.expense_account_id is not null or not exists(select 1 from jsonb_array_elements(matching_items) x where (x->>'product_id')::uuid=l.product_id and (x->>'quantity')::numeric=l.quantity))) or exists(select 1 from purchase_bill_lines where bill_id=bill.id group by product_id having count(*)>1) then raise exception 'Receipt bill must retain its allocated product quantities';end if;
    inventory_account:=receipt_post.clearing_account_id;
    price_variance:=sub-clearing_cost;
    if price_variance<>0 then
      insert into accounts(company_id,code,name,type,system_account)
      values(bill.company_id,'5060','Purchase Price Variance','expense',true)
      on conflict(company_id,code) do nothing;
      select id into variance_account from accounts where company_id=bill.company_id and code='5060'
        and active and system_account and type='expense' and name='Purchase Price Variance';
      if variance_account is null then raise exception 'Purchase price variance account-code conflict: review account 5060'; end if;
    end if;
  end if;
  insert into journal_entries(company_id,branch_id,entry_date,reference,description,created_by)
  values(bill.company_id,bill.branch_id,bill.bill_date,'BILL-'||lpad(bill.bill_number::text,6,'0'),'Supplier bill',auth.uid()) returning id into new_journal;
  if receipt_post.id is not null then
    if clearing_cost>0 then
      insert into journal_lines(entry_id,account_id,description,debit,credit)
      values(new_journal,inventory_account,'Goods received accrual cleared',clearing_cost,0);
    end if;
    if price_variance>0 then
      insert into journal_lines(entry_id,account_id,description,debit,credit)
      values(new_journal,variance_account,'Purchase price variance — receipt cost retained',price_variance,0);
    elsif price_variance<0 then
      insert into journal_lines(entry_id,account_id,description,debit,credit)
      values(new_journal,variance_account,'Purchase price variance — receipt cost retained',0,-price_variance);
    end if;
  else
    insert into journal_lines(entry_id,account_id,description,debit,credit)
    select new_journal,coalesce(l.expense_account_id,inventory_account),l.description,sum(l.subtotal),0
    from purchase_bill_lines l where l.bill_id=bill.id group by coalesce(l.expense_account_id,inventory_account),l.description;
  end if;
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
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare bill purchase_bills%rowtype; reversal_id uuid; line record; receipt_post goods_receipt_postings%rowtype;
begin
  select * into bill from purchase_bills where id=target_bill and status='posted' for update;
  if bill.id is null or not has_company_permission(bill.company_id,'purchases') then raise exception 'Posted bill not found or purchase access denied'; end if;
  if bill.amount_paid>0 then raise exception 'Paid bill cannot be voided; reverse its payment first'; end if;
  select p.* into receipt_post from goods_receipt_postings p join (select receipt_id,bill_id from goods_receipt_bill_links union all select receipt_id,bill_id from goods_receipt_partial_bills) l on l.receipt_id=p.receipt_id where l.bill_id=bill.id for update of p;
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

create or replace function public.reverse_goods_receipt(target_receipt uuid,reason text) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare r goods_document_drafts%rowtype; p goods_receipt_postings%rowtype; item jsonb; result uuid; movement_count bigint;
begin
 select * into r from goods_document_drafts where id=target_receipt for update;
 if not found or not has_company_permission(r.company_id,'purchases') or not has_company_permission(r.company_id,'inventory') or not has_company_permission(r.company_id,'accounting') then raise exception 'Access denied';end if;
 select * into p from goods_receipt_postings where receipt_id=r.id for update;
 if not found then raise exception 'Posted receipt not found';end if;if p.status='reversed' then return p.reversal_id;end if;
 if length(trim(coalesce(reason,'')))<3 then raise exception 'Reversal reason required';end if;
 if exists(select 1 from goods_receipt_partial_bills l join purchase_bills b on b.id=l.bill_id where l.receipt_id=r.id and b.status<>'void') then raise exception 'Delete or void all partial bills before reversing the receipt';end if;
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

commit;
