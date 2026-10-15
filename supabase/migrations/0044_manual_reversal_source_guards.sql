begin;
-- The manual journal endpoint must not bypass source-document stock/payment logic.
create or replace function public.reverse_manual_journal(target_entry uuid,target_reason text default null)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare source journal_entries%rowtype;
begin
 select * into source from journal_entries where id=target_entry and status='posted' for update;
 if source.id is null or not has_company_permission(source.company_id,'accounting') then raise exception 'Posted journal not found or accounting access denied'; end if;
 if source.reversal_of is not null then raise exception 'Reversal entries cannot be reversed again; create a new reviewed transaction'; end if;
 if exists(select 1 from sales_invoices where journal_entry_id=source.id)
 or exists(select 1 from purchase_bills where journal_entry_id=source.id)
 or exists(select 1 from payroll_runs where journal_entry_id=source.id)
 or exists(select 1 from payments where journal_entry_id=source.id)
 or exists(select 1 from sales_credit_notes where journal_entry_id=source.id)
 or exists(select 1 from purchase_debit_notes where journal_entry_id=source.id) then
  raise exception 'Reverse this entry from its source document to preserve stock, GST and payment balances';
 end if;
 return create_journal_reversal(source.id,target_reason);
end $$;
-- Write-off reversal already checks both inventory and accounting permission,
-- scopes movements to the journal company, and atomically restores stock.
-- Run it as a source RPC so it can call the private reversal helper.
alter function public.reverse_inventory_writeoff(uuid) security definer;
alter function public.reverse_inventory_writeoff(uuid) set search_path=public,pg_temp;
-- Source RPCs may invoke this internal helper; authenticated clients may not.
revoke all on function public.create_journal_reversal(uuid,text) from public,anon,authenticated;
revoke all on function public.reverse_manual_journal(uuid,text) from public,anon;
grant execute on function public.reverse_manual_journal(uuid,text) to authenticated;
commit;
