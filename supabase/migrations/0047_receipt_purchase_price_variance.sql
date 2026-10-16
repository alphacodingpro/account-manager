-- Append-only: expense purchase price differences without changing receipt valuation.
create or replace function public.post_purchase_bill(target_bill uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare bill purchase_bills%rowtype; sub numeric(18,2); tax numeric(18,2); grand numeric(18,2);
  ap_account uuid; inventory_account uuid; input_tax_account uuid; new_journal uuid; line record; receipt_post goods_receipt_postings%rowtype; price_variance numeric(18,2); variance_account uuid;
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
    if (select count(*) from purchase_bill_lines where bill_id=bill.id)<>jsonb_array_length(receipt_post.items) or exists(select 1 from purchase_bill_lines l where l.bill_id=bill.id and (l.expense_account_id is not null or not exists(select 1 from jsonb_array_elements(receipt_post.items) x where (x->>'product_id')::uuid=l.product_id and (x->>'quantity')::numeric=l.quantity))) or exists(select 1 from purchase_bill_lines where bill_id=bill.id group by product_id having count(*)>1) then raise exception 'Costed receipt requires full quantities; partial matching needs review';end if;
    inventory_account:=receipt_post.clearing_account_id;
    price_variance:=sub-receipt_post.total;
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
    insert into journal_lines(entry_id,account_id,description,debit,credit)
    values(new_journal,inventory_account,'Goods received accrual cleared',receipt_post.total,0);
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


revoke all on function public.post_purchase_bill(uuid) from public,anon;
grant execute on function public.post_purchase_bill(uuid) to authenticated;
