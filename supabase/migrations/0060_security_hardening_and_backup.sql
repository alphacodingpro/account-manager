-- 1. Signed-out visitors (the anon role) can no longer execute any database function.
--    Every function already refuses callers without a company membership; this closes the door entirely.
-- 2. export_company_data(): one-click full backup of a company's records for owners and admins.

begin;

create or replace function public.export_company_data(target_company uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare result jsonb; t record; c record; rows jsonb;
begin
  if auth.uid() is null or not exists(select 1 from public.company_members m where m.company_id=target_company
     and m.user_id=auth.uid() and m.active and m.role in ('owner','admin')) then
    raise exception 'Only an owner or admin can export company data';
  end if;
  result:=jsonb_build_object('format','cloudledger-backup-v1','exported_at',now(),'company_id',target_company);
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into rows from public.companies x where x.id=target_company;
  result:=result||jsonb_build_object('companies',rows);
  for t in
    select cl.relname from pg_class cl join pg_namespace n on n.oid=cl.relnamespace
    where n.nspname='public' and cl.relkind='r' and cl.relname not in ('document_counters','companies')
      and exists(select 1 from pg_attribute a where a.attrelid=cl.oid and a.attname='company_id' and not a.attisdropped)
    order by cl.relname
  loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x)),''[]''::jsonb) from public.%I x where x.company_id=$1',t.relname) into rows using target_company;
    result:=result||jsonb_build_object(t.relname,rows);
  end loop;
  for c in select * from (values
    ('journal_lines','entry_id','journal_entries'),('sales_invoice_lines','invoice_id','sales_invoices'),
    ('purchase_bill_lines','bill_id','purchase_bills'),('quotation_lines','quotation_id','quotations'),
    ('sales_order_lines','sales_order_id','sales_orders'),('purchase_order_lines','purchase_order_id','purchase_orders'),
    ('sales_credit_note_lines','credit_note_id','sales_credit_notes'),('purchase_debit_note_lines','debit_note_id','purchase_debit_notes'),
    ('payroll_items','payroll_run_id','payroll_runs'),('employee_salary_components','employee_id','employees'),
    ('bank_statement_lines','bank_account_id','bank_accounts')
  ) as v(child,fk,parent) loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x)),''[]''::jsonb) from public.%I x where x.%I in (select p.id from public.%I p where p.company_id=$1)',c.child,c.fk,c.parent) into rows using target_company;
    result:=result||jsonb_build_object(c.child,rows);
  end loop;
  return result;
end; $$;

revoke execute on all functions in schema public from public,anon;
grant execute on all functions in schema public to authenticated;
alter default privileges in schema public revoke execute on functions from public,anon;
alter default privileges in schema public grant execute on functions to authenticated;

commit;
