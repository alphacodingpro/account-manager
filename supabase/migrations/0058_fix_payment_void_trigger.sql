-- Fix: voiding a posted payment/receipt failed with: record "new" has no field "amount_paid".
-- protect_posted_business_document() is shared by purchase_bills, payments and payroll_runs, but it read
-- new.amount_paid / new.total directly. PostgreSQL resolves those record fields when the expression is
-- planned, so any table without the column (payments, payroll_runs) raised an error even though the
-- branch was meant for purchase_bills only. The checks below read the values from JSON instead, so the
-- rules are identical but valid for every table.

begin;

create or replace function public.protect_posted_business_document()
returns trigger language plpgsql as $$
declare new_paid numeric; old_paid numeric; new_total numeric;
begin
  if tg_op='DELETE' and old.status not in ('draft','approved') then raise exception 'Posted document is immutable'; end if;
  if tg_op='UPDATE' and old.status not in ('draft','approved') then
    if tg_table_name='purchase_bills' then
      new_paid:=(to_jsonb(new)->>'amount_paid')::numeric;
      old_paid:=(to_jsonb(old)->>'amount_paid')::numeric;
      new_total:=(to_jsonb(new)->>'total')::numeric;
      if old.status in ('posted','part_paid') and new.status='void'
        and current_setting('cloudledger.allow_document_void',true)='on'
        and (to_jsonb(new)-'status')=(to_jsonb(old)-'status') then return new; end if;
      if current_setting('cloudledger.allow_payment_reversal',true)='on'
        and (to_jsonb(new)-'amount_paid'-'status')=(to_jsonb(old)-'amount_paid'-'status')
        and new_paid>=0 and new_paid<=new_total and new.status in ('posted','part_paid','paid') then return new; end if;
      if (to_jsonb(new)-'amount_paid'-'status')=(to_jsonb(old)-'amount_paid'-'status')
        and new_paid>=old_paid and new.status in ('posted','part_paid','paid') then return new; end if;
    end if;
    if tg_table_name='payments' and old.status='posted' and new.status='void'
      and current_setting('cloudledger.allow_payment_reversal',true)='on'
      and (to_jsonb(new)-'status')=(to_jsonb(old)-'status') then return new; end if;
    raise exception 'Posted document is immutable';
  end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;

commit;
