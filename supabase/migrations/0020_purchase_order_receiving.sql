-- Purchase orders are non-posting commitments. Receiving creates a purchase
-- bill draft; stock and AP remain controlled by post_purchase_bill.
begin;

create table if not exists public.purchase_orders (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict, warehouse_id uuid references public.warehouses(id) on delete restrict,
  supplier_id uuid not null references public.contacts(id) on delete restrict, order_number bigint generated always as identity,
  order_date date not null, expected_date date, supplier_reference text, notes text,
  status public.business_document_status not null default 'draft', subtotal numeric(18,2) not null default 0,
  gst_total numeric(18,2) not null default 0, total numeric(18,2) not null default 0,
  converted_bill_id uuid references public.purchase_bills(id) on delete restrict,
  created_by uuid not null references auth.users(id), created_at timestamptz not null default now()
);
create unique index if not exists purchase_orders_one_converted_bill on public.purchase_orders(converted_bill_id) where converted_bill_id is not null;
alter table public.purchase_bills add column if not exists purchase_order_id uuid references public.purchase_orders(id) on delete restrict;
create unique index if not exists purchase_bills_one_per_order on public.purchase_bills(purchase_order_id) where purchase_order_id is not null;

create table if not exists public.purchase_order_lines (
  id uuid primary key default gen_random_uuid(), purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete restrict, expense_account_id uuid references public.accounts(id) on delete restrict,
  description text not null, quantity numeric(18,3) not null check(quantity>0), unit_price numeric(18,2) not null check(unit_price>=0),
  gst_rate numeric(5,2) not null default 0 check(gst_rate between 0 and 100),
  subtotal numeric(18,2) generated always as (round(quantity*unit_price,2)) stored,
  gst_amount numeric(18,2) generated always as (round(quantity*unit_price*gst_rate/100,2)) stored,
  total numeric(18,2) generated always as (round(quantity*unit_price*(1+gst_rate/100),2)) stored,
  check(product_id is not null or expense_account_id is not null)
);

alter table public.purchase_orders enable row level security;
alter table public.purchase_order_lines enable row level security;
create policy "members read purchase orders" on public.purchase_orders for select using(public.is_company_member(company_id));
create policy "purchase staff manage orders" on public.purchase_orders for all
  using(public.has_company_permission(company_id,'purchases')) with check(public.has_company_permission(company_id,'purchases'));
create policy "members read purchase order lines" on public.purchase_order_lines for select
  using(exists(select 1 from public.purchase_orders o where o.id=purchase_order_id and public.is_company_member(o.company_id)));
create policy "purchase staff manage order lines" on public.purchase_order_lines for all
  using(exists(select 1 from public.purchase_orders o where o.id=purchase_order_id and public.has_company_permission(o.company_id,'purchases')))
  with check(exists(select 1 from public.purchase_orders o where o.id=purchase_order_id and public.has_company_permission(o.company_id,'purchases')));

create or replace function public.protect_purchase_order()
returns trigger language plpgsql set search_path=public as $$
begin
  if tg_op='INSERT' then
    if new.status<>'draft' or new.subtotal<>0 or new.gst_total<>0 or new.total<>0 or new.converted_bill_id is not null then raise exception 'New purchase order must start as an empty draft'; end if;
    return new;
  end if;
  if old.status='draft' then
    if tg_op='UPDATE' and (new.status<>old.status or new.converted_bill_id is distinct from old.converted_bill_id)
      and coalesce(current_setting('cloudledger.allow_purchase_order_transition',true),'')<>'on' then raise exception 'Use the controlled purchase order workflow'; end if;
    return case when tg_op='DELETE' then old else new end;
  end if;
  if tg_op='UPDATE' and current_setting('cloudledger.allow_purchase_order_transition',true)='on'
    and (to_jsonb(new)-'status'-'converted_bill_id')=(to_jsonb(old)-'status'-'converted_bill_id') then return new; end if;
  raise exception 'Approved purchase order is immutable';
end; $$;
create trigger purchase_order_immutable before insert or update or delete on public.purchase_orders for each row execute function public.protect_purchase_order();

create or replace function public.protect_purchase_order_lines()
returns trigger language plpgsql set search_path=public as $$
declare parent_status public.business_document_status;
begin
  select status into parent_status from public.purchase_orders where id=coalesce(new.purchase_order_id,old.purchase_order_id);
  if parent_status is distinct from 'draft' then raise exception 'Approved purchase order lines are immutable'; end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;
create trigger purchase_order_lines_immutable before insert or update or delete on public.purchase_order_lines for each row execute function public.protect_purchase_order_lines();

create or replace function public.approve_purchase_order(target_order uuid)
returns void language plpgsql security definer set search_path=public as $$
declare o public.purchase_orders%rowtype; sub numeric(18,2); tax numeric(18,2); grand numeric(18,2);
begin
  select * into o from public.purchase_orders where id=target_order and status='draft' for update;
  if o.id is null or not public.has_company_permission(o.company_id,'purchases') then raise exception 'Purchase order not found or purchase access denied'; end if;
  if not exists(select 1 from public.contacts where id=o.supplier_id and company_id=o.company_id and kind in ('supplier','both') and active) then raise exception 'Invalid supplier'; end if;
  if not exists(select 1 from public.branches where id=o.branch_id and company_id=o.company_id and active) then raise exception 'Invalid branch'; end if;
  if o.warehouse_id is not null and not exists(select 1 from public.warehouses where id=o.warehouse_id and company_id=o.company_id and branch_id=o.branch_id and active) then raise exception 'Invalid warehouse'; end if;
  if o.expected_date is not null and o.expected_date<o.order_date then raise exception 'Expected date cannot precede order date'; end if;
  if exists(select 1 from public.purchase_order_lines l join public.products p on p.id=l.product_id where l.purchase_order_id=o.id and (p.company_id<>o.company_id or not p.active)) then raise exception 'Invalid or inactive product'; end if;
  if exists(select 1 from public.purchase_order_lines l join public.accounts a on a.id=l.expense_account_id where l.purchase_order_id=o.id and (a.company_id<>o.company_id or a.type<>'expense' or not a.active)) then raise exception 'Invalid expense account'; end if;
  if exists(select 1 from public.purchase_order_lines l left join public.products p on p.id=l.product_id where l.purchase_order_id=o.id and (l.product_id is null or p.is_service) and l.expense_account_id is null) then raise exception 'Expense account is required for non-stock lines'; end if;
  if exists(select 1 from public.purchase_order_lines l join public.products p on p.id=l.product_id where l.purchase_order_id=o.id and not p.is_service) and o.warehouse_id is null then raise exception 'Warehouse is required for stock purchases'; end if;
  select coalesce(sum(subtotal),0),coalesce(sum(gst_amount),0),coalesce(sum(total),0) into sub,tax,grand from public.purchase_order_lines where purchase_order_id=o.id;
  if grand<=0 then raise exception 'Purchase order requires at least one positive line'; end if;
  perform set_config('cloudledger.allow_purchase_order_transition','on',true);
  update public.purchase_orders set subtotal=sub,gst_total=tax,total=grand,status='approved' where id=o.id;
end; $$;

create or replace function public.receive_purchase_order_to_bill(target_order uuid,target_due_date date)
returns uuid language plpgsql security definer set search_path=public as $$
declare o public.purchase_orders%rowtype; new_bill uuid;
begin
  select * into o from public.purchase_orders where id=target_order and status='approved' for update;
  if o.id is null or not public.has_company_permission(o.company_id,'purchases') then raise exception 'Approved purchase order not found or purchase access denied'; end if;
  if o.converted_bill_id is not null then raise exception 'Purchase order has already been received to a bill'; end if;
  if target_due_date is null or target_due_date<current_date then raise exception 'Bill due date cannot be in the past'; end if;
  insert into public.purchase_bills(company_id,branch_id,warehouse_id,supplier_id,supplier_reference,bill_date,due_date,notes,purchase_order_id,created_by)
  values(o.company_id,o.branch_id,o.warehouse_id,o.supplier_id,o.supplier_reference,current_date,target_due_date,
    concat('Created from PO-',lpad(o.order_number::text,6,'0'),case when o.notes is null then '' else ': '||o.notes end),o.id,auth.uid()) returning id into new_bill;
  insert into public.purchase_bill_lines(bill_id,product_id,expense_account_id,description,quantity,unit_price,gst_rate)
  select new_bill,product_id,expense_account_id,description,quantity,unit_price,gst_rate from public.purchase_order_lines where purchase_order_id=o.id;
  perform set_config('cloudledger.allow_purchase_order_transition','on',true);
  update public.purchase_orders set converted_bill_id=new_bill where id=o.id;
  return new_bill;
end; $$;

create trigger purchase_order_audit after insert or update or delete on public.purchase_orders for each row execute function public.write_audit_log();
revoke all on function public.approve_purchase_order(uuid) from public,anon;
revoke all on function public.receive_purchase_order_to_bill(uuid,date) from public,anon;
grant execute on function public.approve_purchase_order(uuid) to authenticated;
grant execute on function public.receive_purchase_order_to_bill(uuid,date) to authenticated;
commit;
