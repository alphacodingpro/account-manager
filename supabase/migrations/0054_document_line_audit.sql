begin;
-- Record actual line changes without bypassing or changing mutation/RLS guards.
create function public.audit_document_line_change()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare parent_table text; parent_key text; before_line jsonb; after_line jsonb; before_id uuid; after_id uuid; source jsonb; target uuid; kind text;
begin
 case tg_table_name
 when 'sales_invoice_lines' then parent_table:='sales_invoices';parent_key:='invoice_id';
 when 'purchase_bill_lines' then parent_table:='purchase_bills';parent_key:='bill_id';
 when 'quotation_lines' then parent_table:='quotations';parent_key:='quotation_id';
 when 'sales_order_lines' then parent_table:='sales_orders';parent_key:='sales_order_id';
 when 'purchase_order_lines' then parent_table:='purchase_orders';parent_key:='purchase_order_id';
 when 'sales_credit_note_lines' then parent_table:='sales_credit_notes';parent_key:='credit_note_id';
 when 'purchase_debit_note_lines' then parent_table:='purchase_debit_notes';parent_key:='debit_note_id';
 when 'journal_lines' then parent_table:='journal_entries';parent_key:='entry_id';
 else raise exception 'Unsupported audit source';end case;
 if tg_op in ('UPDATE','DELETE') then before_line:=to_jsonb(old);before_id:=(before_line->>parent_key)::uuid;end if;
 if tg_op in ('UPDATE','INSERT') then after_line:=to_jsonb(new);after_id:=(after_line->>parent_key)::uuid;end if;
 if tg_op='UPDATE' and before_line=after_line then return new;end if;
 -- A move is two separate company-scoped events; never copy another company's
 -- before-values into the destination company's history.
 for target in select distinct x from unnest(array[before_id,after_id]) x where x is not null loop
  execute format('select to_jsonb(t) from public.%I t where id=$1',parent_table) into source using target;
  -- A cascading parent delete is covered by the existing document deletion snapshot.
  if source is null then continue;end if;
  kind:=case when target=before_id and target=after_id then 'LINE_UPDATE' when target=before_id then 'LINE_DELETE' else 'LINE_INSERT' end;
  insert into public.audit_log(company_id,user_id,action,entity_type,entity_id,old_values,new_values)
  values((source->>'company_id')::uuid,auth.uid(),kind,parent_table,target::text,
   case when target=before_id then source||jsonb_build_object('line_table',tg_table_name,'line',before_line) end,
   case when target=after_id then source||jsonb_build_object('line_table',tg_table_name,'line',after_line) end);
 end loop;
 return case when tg_op='DELETE' then old else new end;
end $$;
revoke all on function public.audit_document_line_change() from public,anon,authenticated;
create trigger sales_invoice_line_audit after insert or update or delete on public.sales_invoice_lines for each row execute function public.audit_document_line_change();
create trigger purchase_bill_line_audit after insert or update or delete on public.purchase_bill_lines for each row execute function public.audit_document_line_change();
create trigger quotation_line_audit after insert or update or delete on public.quotation_lines for each row execute function public.audit_document_line_change();
create trigger sales_order_line_audit after insert or update or delete on public.sales_order_lines for each row execute function public.audit_document_line_change();
create trigger purchase_order_line_audit after insert or update or delete on public.purchase_order_lines for each row execute function public.audit_document_line_change();
create trigger sales_credit_note_line_audit after insert or update or delete on public.sales_credit_note_lines for each row execute function public.audit_document_line_change();
create trigger purchase_debit_note_line_audit after insert or update or delete on public.purchase_debit_note_lines for each row execute function public.audit_document_line_change();
create trigger journal_line_audit after insert or update or delete on public.journal_lines for each row execute function public.audit_document_line_change();
-- Core invoice/bill deletion snapshots already exist in 0028. Cover the other
-- six document families before FK cascades remove their line evidence.
create function public.audit_deleted_document_lines()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare child text; parent_key text; children jsonb;
begin
 case tg_table_name
 when 'quotations' then child:='quotation_lines';parent_key:='quotation_id';
 when 'sales_orders' then child:='sales_order_lines';parent_key:='sales_order_id';
 when 'purchase_orders' then child:='purchase_order_lines';parent_key:='purchase_order_id';
 when 'sales_credit_notes' then child:='sales_credit_note_lines';parent_key:='credit_note_id';
 when 'purchase_debit_notes' then child:='purchase_debit_note_lines';parent_key:='debit_note_id';
 when 'journal_entries' then child:='journal_lines';parent_key:='entry_id';
 else raise exception 'Unsupported deleted audit source';end case;
 execute format('select coalesce(jsonb_agg(to_jsonb(t) order by t.id),''[]''::jsonb) from public.%I t where %I=$1',child,parent_key) into children using old.id;
 insert into public.audit_log(company_id,user_id,action,entity_type,entity_id,old_values)
 values(old.company_id,auth.uid(),'DOCUMENT_DELETE',tg_table_name,old.id::text,to_jsonb(old)||jsonb_build_object('_lines',children));
 return old;
end $$;
revoke all on function public.audit_deleted_document_lines() from public,anon,authenticated;
create trigger quotation_deleted_line_audit before delete on public.quotations for each row execute function public.audit_deleted_document_lines();
create trigger sales_order_deleted_line_audit before delete on public.sales_orders for each row execute function public.audit_deleted_document_lines();
create trigger purchase_order_deleted_line_audit before delete on public.purchase_orders for each row execute function public.audit_deleted_document_lines();
create trigger sales_credit_deleted_line_audit before delete on public.sales_credit_notes for each row execute function public.audit_deleted_document_lines();
create trigger purchase_debit_deleted_line_audit before delete on public.purchase_debit_notes for each row execute function public.audit_deleted_document_lines();
create trigger journal_deleted_line_audit before delete on public.journal_entries for each row execute function public.audit_deleted_document_lines();
-- Preserve draft deletion during FK cascades without permitting posted edits.
create or replace function public.protect_sales_quotation_lines()
returns trigger language plpgsql set search_path=public as $$
declare parent_status public.business_document_status;
begin
  -- The parent guard already approved this FK cascade; ordinary line writes
  -- still require a visible draft parent and all existing RLS policies.
  if tg_op='DELETE' and pg_trigger_depth()>1 and not exists(select 1 from public.quotations where id=old.quotation_id) then return old;end if;
  select status into parent_status from public.quotations where id=coalesce(new.quotation_id,old.quotation_id);
  if parent_status is distinct from 'draft' then raise exception 'Approved quotation lines are immutable'; end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;
create or replace function public.protect_purchase_order_lines()
returns trigger language plpgsql set search_path=public as $$
declare parent_status public.business_document_status;
begin
  -- The parent guard already approved this FK cascade; ordinary line writes
  -- still require a visible draft parent and all existing RLS policies.
  if tg_op='DELETE' and pg_trigger_depth()>1 and not exists(select 1 from public.purchase_orders where id=old.purchase_order_id) then return old;end if;
  select status into parent_status from public.purchase_orders where id=coalesce(new.purchase_order_id,old.purchase_order_id);
  if parent_status is distinct from 'draft' then raise exception 'Approved purchase order lines are immutable'; end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;
create or replace function public.protect_sales_order_lines()
returns trigger language plpgsql set search_path=public as $$
declare parent_status public.business_document_status;
begin
  -- The parent guard already approved this FK cascade; ordinary line writes
  -- still require a visible draft parent and all existing RLS policies.
  if tg_op='DELETE' and pg_trigger_depth()>1 and not exists(select 1 from public.sales_orders where id=old.sales_order_id) then return old;end if;
  select status into parent_status from public.sales_orders where id=coalesce(new.sales_order_id,old.sales_order_id);
  if parent_status is distinct from 'draft' then raise exception 'Approved sales-order lines are immutable'; end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;
create or replace function public.protect_sales_credit_note_lines()
returns trigger language plpgsql set search_path=public as $$
declare parent_status public.invoice_status;
begin
  -- The parent guard already approved this FK cascade; ordinary line writes
  -- still require a visible draft parent and all existing RLS policies.
  if tg_op='DELETE' and pg_trigger_depth()>1 and not exists(select 1 from public.sales_credit_notes where id=old.credit_note_id) then return old;end if;
  select status into parent_status from public.sales_credit_notes where id=coalesce(new.credit_note_id,old.credit_note_id);
  if parent_status is distinct from 'draft' then raise exception 'Posted credit-note lines are immutable'; end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;
create or replace function public.protect_purchase_debit_note_lines()
returns trigger language plpgsql set search_path=public as $$
declare parent_status public.business_document_status;
begin
  -- The parent guard already approved this FK cascade; ordinary line writes
  -- still require a visible draft parent and all existing RLS policies.
  if tg_op='DELETE' and pg_trigger_depth()>1 and not exists(select 1 from public.purchase_debit_notes where id=old.debit_note_id) then return old;end if;
  select status into parent_status from public.purchase_debit_notes where id=coalesce(new.debit_note_id,old.debit_note_id);
  if parent_status is distinct from 'draft' then raise exception 'Posted debit-note lines are immutable'; end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;
commit;
