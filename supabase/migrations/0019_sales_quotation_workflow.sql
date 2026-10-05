-- Controlled sales quotations: drafts remain editable, approval freezes terms,
-- and conversion creates an invoice draft without touching stock or the ledger.
begin;

alter table public.quotations add column if not exists converted_invoice_id uuid references public.sales_invoices(id) on delete restrict;
create unique index if not exists quotations_one_converted_invoice on public.quotations(converted_invoice_id) where converted_invoice_id is not null;

drop policy if exists "writers_manage_quotations" on public.quotations;
drop policy if exists "sales staff manage quotations" on public.quotations;
create policy "sales staff manage quotations" on public.quotations for all
  using(public.has_company_permission(company_id,'sales')) with check(public.has_company_permission(company_id,'sales'));
drop policy if exists "writers manage quotation lines" on public.quotation_lines;
drop policy if exists "sales staff manage quotation lines" on public.quotation_lines;
create policy "sales staff manage quotation lines" on public.quotation_lines for all
  using(exists(select 1 from public.quotations q where q.id=quotation_id and public.has_company_permission(q.company_id,'sales')))
  with check(exists(select 1 from public.quotations q where q.id=quotation_id and public.has_company_permission(q.company_id,'sales')));

create or replace function public.protect_sales_quotation()
returns trigger language plpgsql set search_path=public as $$
begin
  if tg_op='INSERT' then
    if new.status<>'draft' or new.subtotal<>0 or new.gst_total<>0 or new.total<>0 or new.converted_invoice_id is not null then raise exception 'New quotation must start as an empty draft'; end if;
    return new;
  end if;
  if old.status='draft' then
    if tg_op='UPDATE' and (new.status<>old.status or new.converted_invoice_id is distinct from old.converted_invoice_id)
      and coalesce(current_setting('cloudledger.allow_quotation_transition',true),'')<>'on' then raise exception 'Use the controlled quotation workflow'; end if;
    return case when tg_op='DELETE' then old else new end;
  else
    if tg_op='UPDATE' and current_setting('cloudledger.allow_quotation_transition',true)='on'
      and (to_jsonb(new)-'status'-'converted_invoice_id')=(to_jsonb(old)-'status'-'converted_invoice_id') then return new; end if;
    raise exception 'Approved quotation is immutable';
  end if;
end; $$;
drop trigger if exists quotation_immutable on public.quotations;
create trigger quotation_immutable before insert or update or delete on public.quotations for each row execute function public.protect_sales_quotation();

create or replace function public.protect_sales_quotation_lines()
returns trigger language plpgsql set search_path=public as $$
declare parent_status public.business_document_status;
begin
  select status into parent_status from public.quotations where id=coalesce(new.quotation_id,old.quotation_id);
  if parent_status is distinct from 'draft' then raise exception 'Approved quotation lines are immutable'; end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;
drop trigger if exists quotation_lines_immutable on public.quotation_lines;
create trigger quotation_lines_immutable before insert or update or delete on public.quotation_lines for each row execute function public.protect_sales_quotation_lines();

create or replace function public.approve_sales_quotation(target_quotation uuid)
returns void language plpgsql security definer set search_path=public as $$
declare q public.quotations%rowtype; sub numeric(18,2); tax numeric(18,2); grand numeric(18,2);
begin
  select * into q from public.quotations where id=target_quotation and status='draft' for update;
  if q.id is null or not public.has_company_permission(q.company_id,'sales') then raise exception 'Quotation not found or sales access denied'; end if;
  if not exists(select 1 from public.contacts where id=q.customer_id and company_id=q.company_id and kind in ('customer','both') and active) then raise exception 'Invalid customer'; end if;
  if not exists(select 1 from public.branches where id=q.branch_id and company_id=q.company_id and active) then raise exception 'Invalid branch'; end if;
  if q.valid_until is not null and q.valid_until<q.quotation_date then raise exception 'Valid-until date cannot precede quotation date'; end if;
  if exists(select 1 from public.quotation_lines l join public.products p on p.id=l.product_id where l.quotation_id=q.id and p.company_id<>q.company_id) then raise exception 'Invalid product company'; end if;
  select coalesce(sum(subtotal),0),coalesce(sum(gst_amount),0),coalesce(sum(total),0) into sub,tax,grand from public.quotation_lines where quotation_id=q.id;
  if grand<=0 then raise exception 'Quotation requires at least one positive line'; end if;
  perform set_config('cloudledger.allow_quotation_transition','on',true);
  update public.quotations set subtotal=sub,gst_total=tax,total=grand,status='approved' where id=q.id;
end; $$;

create or replace function public.convert_sales_quotation(target_quotation uuid,target_due_date date)
returns uuid language plpgsql security definer set search_path=public as $$
declare q public.quotations%rowtype; new_invoice uuid;
begin
  select * into q from public.quotations where id=target_quotation and status='approved' for update;
  if q.id is null or not public.has_company_permission(q.company_id,'sales') then raise exception 'Approved quotation not found or sales access denied'; end if;
  if q.converted_invoice_id is not null then raise exception 'Quotation has already been converted'; end if;
  if target_due_date is null or target_due_date<current_date then raise exception 'Invoice due date cannot be in the past'; end if;
  insert into public.sales_invoices(company_id,branch_id,customer_id,invoice_date,due_date,reference,notes,created_by)
  values(q.company_id,q.branch_id,q.customer_id,current_date,target_due_date,'QT-'||lpad(q.quotation_number::text,6,'0'),q.notes,auth.uid()) returning id into new_invoice;
  insert into public.sales_invoice_lines(invoice_id,product_id,description,quantity,unit_price,gst_rate)
  select new_invoice,product_id,description,quantity,unit_price,gst_rate from public.quotation_lines where quotation_id=q.id;
  perform set_config('cloudledger.allow_quotation_transition','on',true);
  update public.quotations set converted_invoice_id=new_invoice where id=q.id;
  return new_invoice;
end; $$;

drop trigger if exists quotation_audit on public.quotations;
create trigger quotation_audit after insert or update or delete on public.quotations for each row execute function public.write_audit_log();
revoke all on function public.approve_sales_quotation(uuid) from public,anon;
revoke all on function public.convert_sales_quotation(uuid,date) from public,anon;
grant execute on function public.approve_sales_quotation(uuid) to authenticated;
grant execute on function public.convert_sales_quotation(uuid,date) to authenticated;
commit;
