create type public.contact_kind as enum ('customer','supplier','both');
create type public.invoice_status as enum ('draft','posted','paid','void');

create table public.contacts (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  kind public.contact_kind not null default 'customer', name text not null, email text, phone text,
  address text, ntn text, strn text, opening_balance numeric(18,2) not null default 0,
  active boolean not null default true, created_at timestamptz not null default now()
);

create table public.products (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  sku text not null, name text not null, description text, is_service boolean not null default false,
  unit text not null default 'each', sale_price numeric(18,2) not null default 0 check(sale_price>=0),
  purchase_price numeric(18,2) not null default 0 check(purchase_price>=0),
  gst_rate numeric(5,2) not null default 0 check(gst_rate between 0 and 100),
  quantity_on_hand numeric(18,3) not null default 0, reorder_level numeric(18,3) not null default 0,
  active boolean not null default true, created_at timestamptz not null default now(), unique(company_id,sku)
);

create table public.sales_invoices (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  customer_id uuid not null references public.contacts(id) on delete restrict,
  invoice_number bigint generated always as identity, invoice_date date not null, due_date date not null,
  reference text, notes text, status public.invoice_status not null default 'draft',
  subtotal numeric(18,2) not null default 0, gst_total numeric(18,2) not null default 0,
  total numeric(18,2) not null default 0, amount_paid numeric(18,2) not null default 0,
  journal_entry_id uuid references public.journal_entries(id), created_by uuid not null references auth.users(id),
  posted_at timestamptz, created_at timestamptz not null default now()
);

create table public.sales_invoice_lines (
  id uuid primary key default gen_random_uuid(), invoice_id uuid not null references public.sales_invoices(id) on delete cascade,
  product_id uuid references public.products(id) on delete restrict, description text not null,
  quantity numeric(18,3) not null check(quantity>0), unit_price numeric(18,2) not null check(unit_price>=0),
  gst_rate numeric(5,2) not null default 0 check(gst_rate between 0 and 100),
  subtotal numeric(18,2) generated always as (round(quantity*unit_price,2)) stored,
  gst_amount numeric(18,2) generated always as (round(quantity*unit_price*gst_rate/100,2)) stored,
  total numeric(18,2) generated always as (round(quantity*unit_price+(quantity*unit_price*gst_rate/100),2)) stored
);

create or replace function public.post_sales_invoice(target_invoice uuid)
returns void language plpgsql security definer set search_path=public
as $$
declare inv sales_invoices%rowtype; sub numeric(18,2); tax numeric(18,2); grand numeric(18,2);
  ar_account uuid; sales_account uuid; gst_account uuid; new_journal uuid;
begin
  select * into inv from sales_invoices where id=target_invoice and status='draft' for update;
  if inv.id is null or not can_write_company(inv.company_id) then raise exception 'Invoice not found or access denied'; end if;
  if not exists(select 1 from contacts where id=inv.customer_id and company_id=inv.company_id and active) then raise exception 'Invalid customer'; end if;
  if not exists(select 1 from branches where id=inv.branch_id and company_id=inv.company_id and active) then raise exception 'Invalid branch'; end if;
  if exists(select 1 from sales_invoice_lines l join products p on p.id=l.product_id where l.invoice_id=inv.id and p.company_id<>inv.company_id) then raise exception 'Invalid product company'; end if;
  select coalesce(sum(subtotal),0),coalesce(sum(gst_amount),0),coalesce(sum(total),0) into sub,tax,grand from sales_invoice_lines where invoice_id=inv.id;
  if grand<=0 then raise exception 'Invoice requires at least one line'; end if;
  select id into ar_account from accounts where company_id=inv.company_id and code='1100';
  select id into sales_account from accounts where company_id=inv.company_id and code='4000';
  select id into gst_account from accounts where company_id=inv.company_id and code='2100';
  if ar_account is null or sales_account is null or (tax>0 and gst_account is null) then raise exception 'Required system accounts are missing'; end if;
  insert into journal_entries(company_id,branch_id,entry_date,reference,description,created_by)
    values(inv.company_id,inv.branch_id,inv.invoice_date,'INV-'||lpad(inv.invoice_number::text,6,'0'),'Sales invoice',auth.uid()) returning id into new_journal;
  insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,ar_account,'Customer receivable',grand,0);
  insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,sales_account,'Sales revenue',0,sub);
  if tax>0 then insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,gst_account,'Output GST',0,tax); end if;
  perform post_journal(new_journal);
  update sales_invoices set subtotal=sub,gst_total=tax,total=grand,status='posted',journal_entry_id=new_journal,posted_at=now() where id=inv.id;
end; $$;

create or replace function public.protect_posted_invoice()
returns trigger language plpgsql as $$ begin
  if old.status in ('posted','paid','void') then raise exception 'Posted invoices are immutable'; end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;
create trigger sales_invoice_immutable before update or delete on public.sales_invoices for each row execute function public.protect_posted_invoice();

create or replace function public.protect_posted_invoice_lines()
returns trigger language plpgsql as $$
declare parent_status public.invoice_status;
begin
  select status into parent_status from sales_invoices where id=coalesce(new.invoice_id,old.invoice_id);
  if parent_status in ('posted','paid','void') then raise exception 'Posted invoice lines are immutable'; end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;
create trigger sales_invoice_lines_immutable before insert or update or delete on public.sales_invoice_lines for each row execute function public.protect_posted_invoice_lines();

alter table public.contacts enable row level security; alter table public.products enable row level security;
alter table public.sales_invoices enable row level security; alter table public.sales_invoice_lines enable row level security;
create policy "members read contacts" on public.contacts for select using(is_company_member(company_id));
create policy "writers manage contacts" on public.contacts for all using(can_write_company(company_id)) with check(can_write_company(company_id));
create policy "members read products" on public.products for select using(is_company_member(company_id));
create policy "writers manage products" on public.products for all using(can_write_company(company_id)) with check(can_write_company(company_id));
create policy "members read sales invoices" on public.sales_invoices for select using(is_company_member(company_id));
create policy "writers manage sales invoices" on public.sales_invoices for all using(can_write_company(company_id)) with check(can_write_company(company_id));
create policy "members read sales lines" on public.sales_invoice_lines for select using(exists(select 1 from sales_invoices i where i.id=invoice_id and is_company_member(i.company_id)));
create policy "writers manage sales lines" on public.sales_invoice_lines for all using(exists(select 1 from sales_invoices i where i.id=invoice_id and can_write_company(i.company_id))) with check(exists(select 1 from sales_invoices i where i.id=invoice_id and can_write_company(i.company_id)));
grant execute on function public.post_sales_invoice(uuid) to authenticated;
