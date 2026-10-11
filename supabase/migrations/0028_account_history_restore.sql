begin;
-- Capture complete drafts before cascading line deletion.
create function public.capture_deleted_document()
returns trigger language plpgsql security definer set search_path=public as $$
declare snapshot jsonb; children jsonb;
begin
  if old.status<>'draft' then raise exception 'Only drafts can be deleted'; end if;
  if tg_table_name='sales_invoices' then select coalesce(jsonb_agg(to_jsonb(l)),'[]'::jsonb) into children from sales_invoice_lines l where invoice_id=old.id;
  else select coalesce(jsonb_agg(to_jsonb(l)),'[]'::jsonb) into children from purchase_bill_lines l where bill_id=old.id; end if;
  snapshot:=to_jsonb(old)||jsonb_build_object('_lines',children);
  insert into audit_log(company_id,user_id,action,entity_type,entity_id,old_values)
    values(old.company_id,auth.uid(),'DELETE_SNAPSHOT',tg_table_name,old.id::text,snapshot);
  return old;
end; $$;
create trigger sales_deleted_snapshot before delete on public.sales_invoices for each row execute function public.capture_deleted_document();
create trigger purchase_deleted_snapshot before delete on public.purchase_bills for each row execute function public.capture_deleted_document();
-- Cover company-owned tables that do not already have an audit trigger.
do $$ declare t record; begin
  for t in select c.table_name from information_schema.columns c where c.table_schema='public' and c.column_name='company_id'
    and c.table_name<>'audit_log' and exists(select 1 from information_schema.tables x where x.table_schema='public' and x.table_name=c.table_name and x.table_type='BASE TABLE')
    and not exists(select 1 from pg_trigger tr join pg_proc p on p.oid=tr.tgfoid where tr.tgrelid=('public.'||quote_ident(c.table_name))::regclass and p.proname='write_audit_log')
  loop execute format('create trigger account_activity_audit after insert or update or delete on public.%I for each row execute function public.write_audit_log()',t.table_name); end loop;
end $$;
create function public.restore_deleted_account_entry(target_activity bigint)
returns uuid language plpgsql security invoker set search_path=public as $$
declare a public.audit_log%rowtype; table_name text; line_table text; parent_field text; columns text; snapshot jsonb; item jsonb; restored_id uuid; permission text;
begin
  perform pg_advisory_xact_lock(target_activity);
  select * into a from audit_log where id=target_activity;
  table_name:=a.entity_type; snapshot:=a.old_values;
  if a.id is null or a.action not in ('DELETE','DELETE_SNAPSHOT') then raise exception 'Deleted snapshot unavailable'; end if;
  if table_name not in ('sales_invoices','purchase_bills','products','contacts','accounts') then raise exception 'This record cannot be restored automatically'; end if;
  permission:=case when table_name='sales_invoices' then 'sales' when table_name='purchase_bills' then 'purchases' when table_name='products' then 'inventory' else 'accounting' end;
  if not has_company_permission(a.company_id,permission) or (snapshot->>'company_id')::uuid is distinct from a.company_id then raise exception 'Restore access denied'; end if;
  if table_name in ('sales_invoices','purchase_bills') and (a.action<>'DELETE_SNAPSHOT' or snapshot->>'status'<>'draft' or jsonb_typeof(snapshot->'_lines')<>'array') then raise exception 'Complete draft snapshot required'; end if;
  if table_name='products' and coalesce((snapshot->>'quantity_on_hand')::numeric,0)<>0 then raise exception 'Cannot restore an inventory balance'; end if;
  restored_id:=(snapshot->>'id')::uuid;
  select string_agg(quote_ident(attname),',') into columns from pg_attribute where attrelid=('public.'||quote_ident(table_name))::regclass and attnum>0 and not attisdropped and attgenerated='' and attidentity='';
  execute format('insert into public.%I (%s) select %s from jsonb_populate_record(null::public.%I,$1)',table_name,columns,columns,table_name) using snapshot;
  if table_name in ('sales_invoices','purchase_bills') then
    line_table:=case when table_name='sales_invoices' then 'sales_invoice_lines' else 'purchase_bill_lines' end;
    parent_field:=case when table_name='sales_invoices' then 'invoice_id' else 'bill_id' end;
    select string_agg(quote_ident(attname),',') into columns from pg_attribute where attrelid=('public.'||quote_ident(line_table))::regclass and attnum>0 and not attisdropped and attgenerated='' and attidentity='';
    for item in select value from jsonb_array_elements(snapshot->'_lines') loop
      if (item->>parent_field)::uuid is distinct from restored_id then raise exception 'Invalid draft line snapshot'; end if;
      execute format('insert into public.%I (%s) select %s from jsonb_populate_record(null::public.%I,$1)',line_table,columns,columns,line_table) using item;
    end loop;
  end if;
  return restored_id;
end; $$;
revoke all on function public.restore_deleted_account_entry(bigint) from public,anon;
grant execute on function public.restore_deleted_account_entry(bigint) to authenticated;
commit;
