create extension if not exists pgcrypto;

create type public.member_role as enum ('owner','admin','accountant','sales','purchases','inventory','payroll','viewer','custom');
create type public.account_type as enum ('asset','liability','equity','income','expense');
create type public.journal_status as enum ('draft','posted','reversed');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  phone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.companies (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  legal_name text,
  currency_code char(3) not null default 'PKR',
  timezone text not null default 'Asia/Karachi',
  financial_year_start smallint not null default 7 check (financial_year_start between 1 and 12),
  ntn text,
  strn text,
  gst_registered boolean not null default false,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  archived_at timestamptz
);

create table public.company_members (
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role public.member_role not null default 'viewer',
  permissions jsonb not null default '{}'::jsonb,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (company_id,user_id)
);

create table public.branches (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null,
  name text not null,
  address text,
  city text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(company_id,code)
);

create table public.accounts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null,
  name text not null,
  type public.account_type not null,
  parent_id uuid references public.accounts(id),
  system_account boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(company_id,code)
);

create table public.journal_entries (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid references public.branches(id) on delete restrict,
  entry_number bigint generated always as identity,
  entry_date date not null,
  reference text,
  description text,
  status public.journal_status not null default 'draft',
  reversal_of uuid references public.journal_entries(id),
  created_by uuid not null references auth.users(id),
  posted_by uuid references auth.users(id),
  posted_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.journal_lines (
  id uuid primary key default gen_random_uuid(),
  entry_id uuid not null references public.journal_entries(id) on delete cascade,
  account_id uuid not null references public.accounts(id) on delete restrict,
  description text,
  debit numeric(18,2) not null default 0 check (debit >= 0),
  credit numeric(18,2) not null default 0 check (credit >= 0),
  check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0))
);

create table public.audit_log (
  id bigint generated always as identity primary key,
  company_id uuid references public.companies(id),
  user_id uuid references auth.users(id),
  action text not null,
  entity_type text not null,
  entity_id text,
  old_values jsonb,
  new_values jsonb,
  created_at timestamptz not null default now()
);

create or replace function public.is_company_member(target_company uuid)
returns boolean language sql stable security definer set search_path = public
as $$ select exists(select 1 from company_members where company_id=target_company and user_id=auth.uid() and active); $$;

create or replace function public.create_company(company_name text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare new_company uuid; new_branch uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  insert into companies(name,created_by) values(trim(company_name),auth.uid()) returning id into new_company;
  insert into company_members(company_id,user_id,role) values(new_company,auth.uid(),'owner');
  insert into branches(company_id,code,name) values(new_company,'HO','Head Office') returning id into new_branch;
  insert into accounts(company_id,code,name,type,system_account) values
    (new_company,'1000','Cash and Bank','asset',true),(new_company,'1100','Accounts Receivable','asset',true),
    (new_company,'2000','Accounts Payable','liability',true),(new_company,'3000','Owner Equity','equity',true),
    (new_company,'4000','Sales','income',true),(new_company,'5000','Cost of Sales','expense',true),
    (new_company,'6000','Operating Expenses','expense',true),(new_company,'2100','GST Payable','liability',true);
  return new_company;
end; $$;

create or replace function public.post_journal(target_entry uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare target_company uuid; total_debit numeric(18,2); total_credit numeric(18,2); line_count integer;
begin
  select company_id into target_company from journal_entries where id=target_entry and status='draft' for update;
  if target_company is null or not is_company_member(target_company) then raise exception 'Entry not found or access denied'; end if;
  select count(*),coalesce(sum(debit),0),coalesce(sum(credit),0) into line_count,total_debit,total_credit from journal_lines where entry_id=target_entry;
  if line_count < 2 then raise exception 'At least two lines are required'; end if;
  if total_debit <> total_credit then raise exception 'Journal entry is not balanced'; end if;
  update journal_entries set status='posted',posted_by=auth.uid(),posted_at=now() where id=target_entry;
end; $$;

create or replace function public.protect_posted_journal()
returns trigger language plpgsql as $$
begin
  if old.status in ('posted','reversed') then raise exception 'Posted journals are immutable; create a reversal entry'; end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;

create trigger journal_entry_immutable before update or delete on public.journal_entries for each row execute function public.protect_posted_journal();

create or replace function public.protect_posted_lines()
returns trigger language plpgsql as $$
declare parent_status public.journal_status;
begin
  select status into parent_status from journal_entries where id=coalesce(new.entry_id,old.entry_id);
  if parent_status in ('posted','reversed') then raise exception 'Posted journal lines are immutable'; end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;

create trigger journal_lines_immutable before insert or update or delete on public.journal_lines for each row execute function public.protect_posted_lines();

alter table public.profiles enable row level security;
alter table public.companies enable row level security;
alter table public.company_members enable row level security;
alter table public.branches enable row level security;
alter table public.accounts enable row level security;
alter table public.journal_entries enable row level security;
alter table public.journal_lines enable row level security;
alter table public.audit_log enable row level security;

create policy "own profile" on public.profiles for all using(id=auth.uid()) with check(id=auth.uid());
create policy "member companies" on public.companies for select using(public.is_company_member(id));
create policy "authenticated create company" on public.companies for insert to authenticated with check(created_by=auth.uid());
create policy "member list" on public.company_members for select using(public.is_company_member(company_id));
create policy "member branches" on public.branches for all using(public.is_company_member(company_id)) with check(public.is_company_member(company_id));
create policy "member accounts" on public.accounts for all using(public.is_company_member(company_id)) with check(public.is_company_member(company_id));
create policy "member journals" on public.journal_entries for all using(public.is_company_member(company_id)) with check(public.is_company_member(company_id));
create policy "member journal lines" on public.journal_lines for all using(exists(select 1 from journal_entries e where e.id=entry_id and public.is_company_member(e.company_id))) with check(exists(select 1 from journal_entries e where e.id=entry_id and public.is_company_member(e.company_id)));
create policy "member audit log" on public.audit_log for select using(public.is_company_member(company_id));

grant execute on function public.create_company(text) to authenticated;
grant execute on function public.post_journal(uuid) to authenticated;

