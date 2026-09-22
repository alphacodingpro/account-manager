-- Auditable receipt/payment reversals and stricter allocation integrity.
-- Posted payments remain immutable; reversal creates an opposite journal entry.

begin;

create or replace function public.protect_posted_invoice()
returns trigger language plpgsql as $$
begin
  if tg_op='DELETE' and old.status in ('posted','paid','void') then raise exception 'Posted invoices are immutable'; end if;
  if tg_op='UPDATE' and old.status in ('posted','paid','void') then
    if old.status='posted' and new.status='void' and current_setting('cloudledger.allow_document_void',true)='on'
      and (to_jsonb(new)-'status')=(to_jsonb(old)-'status') then return new; end if;
    if current_setting('cloudledger.allow_payment_reversal',true)='on'
      and (to_jsonb(new)-'amount_paid'-'status')=(to_jsonb(old)-'amount_paid'-'status')
      and new.amount_paid>=0 and new.amount_paid<=new.total and new.status in ('posted','paid') then return new; end if;
    if (to_jsonb(new)-'amount_paid'-'status')=(to_jsonb(old)-'amount_paid'-'status')
      and new.amount_paid>=old.amount_paid and new.status in ('posted','paid') then return new; end if;
    raise exception 'Posted invoices are immutable except for payment allocation, reversal or voiding';
  end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;

create or replace function public.protect_posted_business_document()
returns trigger language plpgsql as $$
begin
  if tg_op='DELETE' and old.status not in ('draft','approved') then raise exception 'Posted document is immutable'; end if;
  if tg_op='UPDATE' and old.status not in ('draft','approved') then
    if tg_table_name='purchase_bills' and old.status in ('posted','part_paid') and new.status='void'
      and current_setting('cloudledger.allow_document_void',true)='on'
      and (to_jsonb(new)-'status')=(to_jsonb(old)-'status') then return new; end if;
    if tg_table_name='purchase_bills' and current_setting('cloudledger.allow_payment_reversal',true)='on'
      and (to_jsonb(new)-'amount_paid'-'status')=(to_jsonb(old)-'amount_paid'-'status')
      and new.amount_paid>=0 and new.amount_paid<=new.total and new.status in ('posted','part_paid','paid') then return new; end if;
    if tg_table_name='payments' and old.status='posted' and new.status='void'
      and current_setting('cloudledger.allow_payment_reversal',true)='on'
      and (to_jsonb(new)-'status')=(to_jsonb(old)-'status') then return new; end if;
    if tg_table_name='purchase_bills' and (to_jsonb(new)-'amount_paid'-'status')=(to_jsonb(old)-'amount_paid'-'status')
      and new.amount_paid>=old.amount_paid and new.status in ('posted','part_paid','paid') then return new; end if;
    raise exception 'Posted document is immutable';
  end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;

create or replace function public.post_payment(target_payment uuid)
returns void language plpgsql security definer set search_path=public as $$
declare p payments%rowtype; money_account uuid; control_account uuid; new_journal uuid; remaining numeric(18,2);
begin
  select * into p from payments where id=target_payment and status='draft' for update;
  if p.id is null or not can_write_company(p.company_id) then raise exception 'Payment not found or access denied'; end if;
  if not exists(select 1 from branches where id=p.branch_id and company_id=p.company_id and active) then raise exception 'Invalid branch'; end if;
  if p.contact_id is not null and not exists(select 1 from contacts where id=p.contact_id and company_id=p.company_id and active) then raise exception 'Invalid contact'; end if;
  if p.direction='receipt' and p.purchase_bill_id is not null then raise exception 'A receipt cannot be allocated to a purchase bill'; end if;
  if p.direction='payment' and p.sales_invoice_id is not null then raise exception 'A supplier payment cannot be allocated to a sales invoice'; end if;
  select coalesce(px.cash_account_id,b.ledger_account_id) into money_account from payments px left join bank_accounts b on b.id=px.bank_account_id and b.company_id=px.company_id and b.active where px.id=p.id;
  if money_account is null then raise exception 'Cash or active bank account is required'; end if;
  if not exists(select 1 from accounts a where a.id=money_account and a.company_id=p.company_id and a.active and a.type='asset') then raise exception 'Invalid cash or bank ledger account'; end if;
  if p.direction='receipt' then
    select id into control_account from accounts where company_id=p.company_id and code='1100';
    if p.sales_invoice_id is not null and not exists(select 1 from sales_invoices where id=p.sales_invoice_id and company_id=p.company_id and customer_id=p.contact_id and status='posted' and total-amount_paid>=p.amount) then raise exception 'Invalid customer invoice or receipt exceeds amount due'; end if;
  else
    select id into control_account from accounts where company_id=p.company_id and code='2000';
    if p.purchase_bill_id is not null and not exists(select 1 from purchase_bills where id=p.purchase_bill_id and company_id=p.company_id and supplier_id=p.contact_id and status in ('posted','part_paid') and total-amount_paid>=p.amount) then raise exception 'Invalid supplier bill or payment exceeds amount due'; end if;
  end if;
  if control_account is null then raise exception 'Required control account is missing'; end if;
  insert into journal_entries(company_id,branch_id,entry_date,reference,description,created_by)
  values(p.company_id,p.branch_id,p.payment_date,'PAY-'||lpad(p.payment_number::text,6,'0'),case when p.direction='receipt' then 'Customer receipt' else 'Supplier payment' end,auth.uid()) returning id into new_journal;
  if p.direction='receipt' then
    insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,money_account,'Money received',p.amount,0),(new_journal,control_account,'Receivable settled',0,p.amount);
    if p.sales_invoice_id is not null then
      update sales_invoices set amount_paid=amount_paid+p.amount where id=p.sales_invoice_id returning total-amount_paid into remaining;
      if remaining<=0 then update sales_invoices set status='paid' where id=p.sales_invoice_id; end if;
    end if;
  else
    insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,control_account,'Payable settled',p.amount,0),(new_journal,money_account,'Money paid',0,p.amount);
    if p.purchase_bill_id is not null then
      update purchase_bills set amount_paid=amount_paid+p.amount,status=case when amount_paid+p.amount>=total then 'paid'::business_document_status else 'part_paid'::business_document_status end where id=p.purchase_bill_id returning total-amount_paid into remaining;
    end if;
  end if;
  perform post_journal(new_journal);
  update payments set status='posted',journal_entry_id=new_journal,posted_at=now() where id=p.id;
end; $$;

create or replace function public.void_payment(target_payment uuid,target_reason text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare p payments%rowtype; reversal_id uuid; new_paid numeric(18,2);
begin
  select * into p from payments where id=target_payment and status='posted' for update;
  if p.id is null or not can_write_company(p.company_id) then raise exception 'Posted payment not found or access denied'; end if;
  if exists(select 1 from bank_statement_lines where matched_payment_id=p.id and reconciled) then
    raise exception 'Reconciled payment cannot be reversed; unreconcile the bank statement first';
  end if;
  if p.sales_invoice_id is not null then
    perform 1 from sales_invoices where id=p.sales_invoice_id and company_id=p.company_id for update;
    if not found then raise exception 'Allocated sales invoice not found'; end if;
    select amount_paid-p.amount into new_paid from sales_invoices where id=p.sales_invoice_id;
    if new_paid<0 then raise exception 'Invoice allocation is inconsistent'; end if;
    perform set_config('cloudledger.allow_payment_reversal','on',true);
    update sales_invoices set amount_paid=new_paid,status=case when new_paid>=total then 'paid'::invoice_status else 'posted'::invoice_status end where id=p.sales_invoice_id;
  end if;
  if p.purchase_bill_id is not null then
    perform 1 from purchase_bills where id=p.purchase_bill_id and company_id=p.company_id for update;
    if not found then raise exception 'Allocated purchase bill not found'; end if;
    select amount_paid-p.amount into new_paid from purchase_bills where id=p.purchase_bill_id;
    if new_paid<0 then raise exception 'Bill allocation is inconsistent'; end if;
    perform set_config('cloudledger.allow_payment_reversal','on',true);
    update purchase_bills set amount_paid=new_paid,status=case when new_paid=0 then 'posted'::business_document_status when new_paid<total then 'part_paid'::business_document_status else 'paid'::business_document_status end where id=p.purchase_bill_id;
  end if;
  reversal_id:=create_journal_reversal(p.journal_entry_id,target_reason);
  update bank_statement_lines set matched_payment_id=null where matched_payment_id=p.id and not reconciled;
  perform set_config('cloudledger.allow_payment_reversal','on',true);
  update payments set status='void' where id=p.id;
  return reversal_id;
end; $$;

revoke all on function public.void_payment(uuid,text) from public,anon;
grant execute on function public.void_payment(uuid,text) to authenticated;

commit;
