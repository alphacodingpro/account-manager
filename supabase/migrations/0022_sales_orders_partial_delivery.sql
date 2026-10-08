-- Sales orders are non-posting customer commitments. Partial delivery creates
-- invoice drafts; stock, revenue, GST and receivables post only with the invoice.
begin;

create table if not exists public.sales_orders (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict, customer_id uuid not null references public.contacts(id) on delete restrict,
  order_number bigint generated always as identity, order_date date not null, promised_date date, customer_reference text, notes text,
  status public.business_document_status not null default 'draft', subtotal numeric(18,2) not null default 0,
  gst_total numeric(18,2) not null default 0, total numeric(18,2) not null default 0,
  created_by uuid not null references auth.users(id), created_at timestamptz not null default now()
);
create table if not exists public.sales_order_lines (
  id uuid primary key default gen_random_uuid(), sales_order_id uuid not null references public.sales_orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete restrict, description text not null,
  quantity numeric(18,3) not null check(quantity>0), unit_price numeric(18,2) not null check(unit_price>=0),
  gst_rate numeric(5,2) not null default 0 check(gst_rate between 0 and 100),
  subtotal numeric(18,2) generated always as (round(quantity*unit_price,2)) stored,
  gst_amount numeric(18,2) generated always as (round(quantity*unit_price*gst_rate/100,2)) stored,
  total numeric(18,2) generated always as (round(quantity*unit_price*(1+gst_rate/100),2)) stored
);
alter table public.sales_invoices add column if not exists sales_order_id uuid references public.sales_orders(id) on delete restrict;
alter table public.sales_invoice_lines add column if not exists sales_order_line_id uuid references public.sales_order_lines(id) on delete restrict;
create index if not exists sales_invoice_order_idx on public.sales_invoices(sales_order_id) where sales_order_id is not null;
create index if not exists sales_invoice_lines_order_line_idx on public.sales_invoice_lines(sales_order_line_id) where sales_order_line_id is not null;

alter table public.sales_orders enable row level security;
alter table public.sales_order_lines enable row level security;
create policy "members read sales orders" on public.sales_orders for select using(public.is_company_member(company_id));
create policy "sales staff manage orders" on public.sales_orders for all
  using(public.has_company_permission(company_id,'sales')) with check(public.has_company_permission(company_id,'sales'));
create policy "members read sales order lines" on public.sales_order_lines for select
  using(exists(select 1 from public.sales_orders o where o.id=sales_order_id and public.is_company_member(o.company_id)));
create policy "sales staff manage order lines" on public.sales_order_lines for all
  using(exists(select 1 from public.sales_orders o where o.id=sales_order_id and public.has_company_permission(o.company_id,'sales')))
  with check(exists(select 1 from public.sales_orders o where o.id=sales_order_id and public.has_company_permission(o.company_id,'sales')));

create or replace function public.protect_sales_order()
returns trigger language plpgsql set search_path=public as $$
begin
  if tg_op='INSERT' then
    if new.status<>'draft' or new.subtotal<>0 or new.gst_total<>0 or new.total<>0 then raise exception 'New sales order must start as an empty draft'; end if;
    return new;
  end if;
  if old.status='draft' then
    if tg_op='UPDATE' and new.status<>old.status and coalesce(current_setting('cloudledger.allow_sales_order_transition',true),'')<>'on' then raise exception 'Use the controlled sales-order workflow'; end if;
    return case when tg_op='DELETE' then old else new end;
  end if;
  raise exception 'Approved sales order is immutable';
end; $$;
create trigger sales_order_immutable before insert or update or delete on public.sales_orders for each row execute function public.protect_sales_order();

create or replace function public.protect_sales_order_lines()
returns trigger language plpgsql set search_path=public as $$
declare parent_status public.business_document_status;
begin
  select status into parent_status from public.sales_orders where id=coalesce(new.sales_order_id,old.sales_order_id);
  if parent_status is distinct from 'draft' then raise exception 'Approved sales-order lines are immutable'; end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;
create trigger sales_order_lines_immutable before insert or update or delete on public.sales_order_lines for each row execute function public.protect_sales_order_lines();

create or replace function public.approve_sales_order(target_order uuid)
returns void language plpgsql security definer set search_path=public as $$
declare o public.sales_orders%rowtype; sub numeric(18,2); tax numeric(18,2); grand numeric(18,2);
begin
  select * into o from public.sales_orders where id=target_order and status='draft' for update;
  if o.id is null or not public.has_company_permission(o.company_id,'sales') then raise exception 'Sales order not found or sales access denied'; end if;
  if not exists(select 1 from public.contacts where id=o.customer_id and company_id=o.company_id and kind in ('customer','both') and active) then raise exception 'Invalid customer'; end if;
  if not exists(select 1 from public.branches where id=o.branch_id and company_id=o.company_id and active) then raise exception 'Invalid branch'; end if;
  if o.promised_date is not null and o.promised_date<o.order_date then raise exception 'Promised date cannot precede order date'; end if;
  if exists(select 1 from public.sales_order_lines l join public.products p on p.id=l.product_id where l.sales_order_id=o.id and (p.company_id<>o.company_id or not p.active)) then raise exception 'Invalid or inactive product'; end if;
  select coalesce(sum(subtotal),0),coalesce(sum(gst_amount),0),coalesce(sum(total),0) into sub,tax,grand from public.sales_order_lines where sales_order_id=o.id;
  if grand<=0 then raise exception 'Sales order requires at least one positive line'; end if;
  perform set_config('cloudledger.allow_sales_order_transition','on',true);
  update public.sales_orders set subtotal=sub,gst_total=tax,total=grand,status='approved' where id=o.id;
end; $$;

create or replace function public.validate_sales_order_invoice_header()
returns trigger language plpgsql set search_path=public as $$
declare o public.sales_orders%rowtype;
begin
  if new.sales_order_id is null then return new; end if;
  select * into o from public.sales_orders where id=new.sales_order_id;
  if o.id is null or new.company_id<>o.company_id or new.branch_id<>o.branch_id or new.customer_id<>o.customer_id then
    raise exception 'Sales-order invoice company, branch and customer must match the order';
  end if;
  return new;
end; $$;
create trigger sales_order_invoice_header_valid before insert or update on public.sales_invoices
for each row execute function public.validate_sales_order_invoice_header();

create or replace function public.validate_sales_order_invoice_line()
returns trigger language plpgsql set search_path=public as $$
declare source public.sales_order_lines%rowtype; invoice public.sales_invoices%rowtype; delivered numeric(18,3); exclude_line uuid;
begin
  select * into invoice from public.sales_invoices where id=new.invoice_id;
  if invoice.sales_order_id is null then
    if new.sales_order_line_id is not null then raise exception 'Source order line requires a sales-order invoice'; end if;
    return new;
  end if;
  if new.sales_order_line_id is null then raise exception 'Every sales-order invoice line must reference its source order line'; end if;
  select * into source from public.sales_order_lines where id=new.sales_order_line_id and sales_order_id=invoice.sales_order_id;
  if source.id is null or new.product_id is distinct from source.product_id then raise exception 'Invoice line does not match its sales-order source'; end if;
  if tg_op='UPDATE' then exclude_line:=old.id; end if;
  select coalesce(sum(il.quantity),0) into delivered from public.sales_invoice_lines il join public.sales_invoices i on i.id=il.invoice_id
  where il.sales_order_line_id=source.id and i.status<>'void' and (exclude_line is null or il.id<>exclude_line);
  if delivered+new.quantity>source.quantity then raise exception 'Delivered quantity exceeds the sales-order balance'; end if;
  return new;
end; $$;
create trigger sales_order_invoice_line_valid before insert or update on public.sales_invoice_lines
for each row execute function public.validate_sales_order_invoice_line();

create or replace view public.sales_order_line_progress with (security_invoker=true) as
select o.company_id,l.sales_order_id,l.id as line_id,l.product_id,l.description,l.quantity as ordered_quantity,l.unit_price,l.gst_rate,
  coalesce(sum(case when i.status<>'void' then il.quantity else 0 end),0)::numeric(18,3) as delivered_quantity,
  (l.quantity-coalesce(sum(case when i.status<>'void' then il.quantity else 0 end),0))::numeric(18,3) as remaining_quantity
from public.sales_order_lines l join public.sales_orders o on o.id=l.sales_order_id
left join public.sales_invoice_lines il on il.sales_order_line_id=l.id left join public.sales_invoices i on i.id=il.invoice_id
group by o.company_id,l.sales_order_id,l.id,l.product_id,l.description,l.quantity,l.unit_price,l.gst_rate;
revoke all on public.sales_order_line_progress from public,anon;
grant select on public.sales_order_line_progress to authenticated;

create or replace function public.create_partial_sales_invoice(target_order uuid,target_due_date date,delivery_lines jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare o public.sales_orders%rowtype; new_invoice uuid; requested_count integer; valid_count integer;
begin
  select * into o from public.sales_orders where id=target_order and status='approved' for update;
  if o.id is null or not public.has_company_permission(o.company_id,'sales') then raise exception 'Approved sales order not found or sales access denied'; end if;
  if target_due_date is null or target_due_date<current_date then raise exception 'Invoice due date cannot be in the past'; end if;
  if jsonb_typeof(delivery_lines)<>'array' or jsonb_array_length(delivery_lines)=0 then raise exception 'Select at least one quantity to deliver'; end if;
  if exists(select 1 from jsonb_array_elements(delivery_lines) x group by x->>'line_id' having count(*)>1) then raise exception 'A sales-order line cannot be submitted twice'; end if;
  perform 1 from public.sales_order_lines where sales_order_id=o.id for update;
  requested_count:=jsonb_array_length(delivery_lines);
  select count(*) into valid_count from jsonb_array_elements(delivery_lines) x
  join public.sales_order_line_progress p on p.line_id=(x->>'line_id')::uuid and p.sales_order_id=o.id
  where (x->>'quantity')::numeric>0 and (x->>'quantity')::numeric<=p.remaining_quantity;
  if valid_count<>requested_count then raise exception 'Delivery contains an invalid line or quantity above the remaining balance'; end if;
  insert into public.sales_invoices(company_id,branch_id,customer_id,invoice_date,due_date,reference,notes,sales_order_id,created_by)
  values(o.company_id,o.branch_id,o.customer_id,current_date,target_due_date,'SO-'||lpad(o.order_number::text,6,'0'),o.notes,o.id,auth.uid()) returning id into new_invoice;
  insert into public.sales_invoice_lines(invoice_id,sales_order_line_id,product_id,description,quantity,unit_price,gst_rate)
  select new_invoice,l.id,l.product_id,l.description,(x->>'quantity')::numeric,l.unit_price,l.gst_rate
  from jsonb_array_elements(delivery_lines) x join public.sales_order_lines l on l.id=(x->>'line_id')::uuid
  where l.sales_order_id=o.id;
  return new_invoice;
end; $$;

create trigger sales_order_audit after insert or update or delete on public.sales_orders for each row execute function public.write_audit_log();
revoke all on function public.approve_sales_order(uuid) from public,anon;
revoke all on function public.create_partial_sales_invoice(uuid,date,jsonb) from public,anon;
grant execute on function public.approve_sales_order(uuid) to authenticated;
grant execute on function public.create_partial_sales_invoice(uuid,date,jsonb) to authenticated;
commit;
