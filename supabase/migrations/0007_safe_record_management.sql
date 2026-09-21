-- Safe record management: drafts may be edited/deleted; posted documents are reversed.
begin;

create or replace function public.protect_posted_journal()
returns trigger language plpgsql as $$
begin
  if old.status in ('posted','reversed') then
    if tg_op='UPDATE' and old.status='posted' and new.status='reversed'
      and current_setting('cloudledger.allow_reversal',true)='on'
      and (to_jsonb(new)-'status')=(to_jsonb(old)-'status') then return new; end if;
    raise exception 'Posted journals are immutable; create a reversal entry';
  end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;

create or replace function public.create_journal_reversal(target_entry uuid,target_reason text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare source journal_entries%rowtype; reversal_id uuid;
begin
  select * into source from journal_entries where id=target_entry and status='posted' for update;
  if source.id is null or not can_write_company(source.company_id) then raise exception 'Posted journal not found or access denied'; end if;
  insert into journal_entries(company_id,branch_id,entry_date,reference,description,reversal_of,created_by)
  values(source.company_id,source.branch_id,current_date,'REV-'||source.entry_number,
    coalesce(nullif(trim(target_reason),''),'Reversal: '||coalesce(source.description,source.reference,'journal entry')),source.id,auth.uid())
  returning id into reversal_id;
  insert into journal_lines(entry_id,account_id,description,debit,credit)
  select reversal_id,account_id,'Reversal: '||coalesce(description,''),credit,debit from journal_lines where entry_id=source.id;
  perform post_journal(reversal_id);
  perform set_config('cloudledger.allow_reversal','on',true);
  update journal_entries set status='reversed' where id=source.id;
  return reversal_id;
end; $$;

create or replace function public.reverse_manual_journal(target_entry uuid,target_reason text default null)
returns uuid language plpgsql security definer set search_path=public as $$
begin
  if exists(select 1 from sales_invoices where journal_entry_id=target_entry)
    or exists(select 1 from purchase_bills where journal_entry_id=target_entry)
    or exists(select 1 from payroll_runs where journal_entry_id=target_entry)
    or exists(select 1 from payments where journal_entry_id=target_entry) then
    raise exception 'Reverse this entry from its source document';
  end if;
  return create_journal_reversal(target_entry,target_reason);
end; $$;

create or replace function public.protect_posted_invoice()
returns trigger language plpgsql as $$
begin
  if tg_op='DELETE' and old.status in ('posted','paid','void') then raise exception 'Posted invoices are immutable'; end if;
  if tg_op='UPDATE' and old.status in ('posted','paid','void') then
    if old.status='posted' and new.status='void' and current_setting('cloudledger.allow_document_void',true)='on'
      and (to_jsonb(new)-'status')=(to_jsonb(old)-'status') then return new; end if;
    if (to_jsonb(new)-'amount_paid'-'status')=(to_jsonb(old)-'amount_paid'-'status')
      and new.amount_paid>=old.amount_paid and new.status in ('posted','paid') then return new; end if;
    raise exception 'Posted invoices are immutable except for payment allocation or voiding';
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
    if tg_table_name='purchase_bills' and (to_jsonb(new)-'amount_paid'-'status')=(to_jsonb(old)-'amount_paid'-'status')
      and new.amount_paid>=old.amount_paid and new.status in ('posted','part_paid','paid') then return new; end if;
    raise exception 'Posted document is immutable';
  end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;

create or replace function public.void_sales_invoice(target_invoice uuid,target_reason text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare inv sales_invoices%rowtype; target_warehouse uuid; reversal_id uuid; line record;
begin
  select * into inv from sales_invoices where id=target_invoice and status='posted' for update;
  if inv.id is null or not can_write_company(inv.company_id) then raise exception 'Posted invoice not found or access denied'; end if;
  if inv.amount_paid>0 then raise exception 'Paid invoice cannot be voided; reverse its receipt first'; end if;
  select id into target_warehouse from warehouses where company_id=inv.company_id and branch_id=inv.branch_id and active order by created_at limit 1;
  for line in select l.product_id,l.quantity,p.purchase_price from sales_invoice_lines l join products p on p.id=l.product_id where l.invoice_id=inv.id and not p.is_service loop
    insert into stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,reference,created_by)
    values(inv.company_id,target_warehouse,line.product_id,'return_in',current_date,line.quantity,line.purchase_price,'sales_invoice_void',inv.id,target_reason,auth.uid());
  end loop;
  reversal_id:=create_journal_reversal(inv.journal_entry_id,target_reason);
  perform set_config('cloudledger.allow_document_void','on',true);
  update sales_invoices set status='void' where id=inv.id;
  return reversal_id;
end; $$;

create or replace function public.void_purchase_bill(target_bill uuid,target_reason text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare bill purchase_bills%rowtype; reversal_id uuid; line record;
begin
  select * into bill from purchase_bills where id=target_bill and status='posted' for update;
  if bill.id is null or not can_write_company(bill.company_id) then raise exception 'Posted bill not found or access denied'; end if;
  if bill.amount_paid>0 then raise exception 'Paid bill cannot be voided; reverse its payment first'; end if;
  for line in select l.product_id,l.quantity,l.unit_price from purchase_bill_lines l join products p on p.id=l.product_id where l.bill_id=bill.id and not p.is_service loop
    insert into stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,reference,created_by)
    values(bill.company_id,bill.warehouse_id,line.product_id,'return_out',current_date,line.quantity,line.unit_price,'purchase_bill_void',bill.id,target_reason,auth.uid());
  end loop;
  reversal_id:=create_journal_reversal(bill.journal_entry_id,target_reason);
  perform set_config('cloudledger.allow_document_void','on',true);
  update purchase_bills set status='void' where id=bill.id;
  return reversal_id;
end; $$;

revoke all on function public.create_journal_reversal(uuid,text) from public,anon,authenticated;
grant execute on function public.reverse_manual_journal(uuid,text) to authenticated;
grant execute on function public.void_sales_invoice(uuid,text) to authenticated;
grant execute on function public.void_purchase_bill(uuid,text) to authenticated;

commit;
