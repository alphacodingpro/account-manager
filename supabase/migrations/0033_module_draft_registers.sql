begin;
create table public.module_records (
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id),
 module text not null, title text not null check(length(trim(title)) between 1 and 160),
 record_date date not null, reference text, notes text, details jsonb not null default '{}' check(jsonb_typeof(details)='object'),
 created_at timestamptz not null default now()
);
create or replace function public.module_permission(module_name text) returns text language sql immutable as $$
 select case
 when module_name in ('Delivery Notes','Billable Time','Withholding Tax Receipts') then 'sales'
 when module_name in ('Purchase Quotes','Goods Receipts') then 'purchases'
 when module_name in ('Inventory Write-offs','Production Orders') then 'inventory'
 when module_name in ('Projects','Investments','Fixed Assets','Depreciation Entries','Intangible Assets','Amortization Entries','Capital Accounts','Special Accounts','Folders') then 'accounting'
 when module_name='Customize' then 'settings' else null end;
$$;
alter table public.module_records add constraint known_module check(public.module_permission(module) is not null);
alter table public.module_records enable row level security;
create policy module_records_access on public.module_records for all to authenticated
 using(public.has_company_permission(company_id,public.module_permission(module)))
 with check(public.has_company_permission(company_id,public.module_permission(module)));
create index module_records_company_module on public.module_records(company_id,module,record_date desc);
create trigger module_records_audit after insert or update or delete on public.module_records for each row execute function public.write_audit_log();
grant select,insert,update,delete on public.module_records to authenticated;

commit;
