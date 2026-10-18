-- Company letterhead details used on exported PDFs (invoices, bills, reports, payslips).
-- Owners/admins already may update their company through the existing "owners update company" policy.

begin;

alter table public.companies
  add column if not exists address text,
  add column if not exists phone text,
  add column if not exists email text,
  add column if not exists website text,
  add column if not exists logo_data_url text;

alter table public.companies
  add constraint companies_letterhead_lengths check (
    coalesce(length(address),0)<=300 and coalesce(length(phone),0)<=60
    and coalesce(length(email),0)<=160 and coalesce(length(website),0)<=160
  ),
  add constraint companies_logo_format check (
    logo_data_url is null
    or (length(logo_data_url)<=400000 and logo_data_url ~ '^data:image/(png|jpeg);base64,[A-Za-z0-9+/=]+$')
  );

commit;
