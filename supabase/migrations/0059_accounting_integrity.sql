-- Accounting integrity pack
--  1. Balance Sheet now balances: current-year and prior-year earnings appear in equity.
--  2. Books lock date: nothing can be posted, changed or voided on or before the lock date.
--  3. Document numbers (INV-, BILL-, PAY-, JV- ...) are sequential per company, not shared by all companies.
--  4. A complete standard chart of accounts for every new and existing company.

begin;

------------------------------------------------------------------ 1. Balance sheet
create or replace function public.get_balance_sheet(target_company uuid,as_of date default current_date)
returns table(account_code text,account_name text,category text,amount numeric)
language plpgsql stable security definer set search_path=public as $$
declare fy_month int; fy_start date;
begin
  if not is_company_member(target_company) then raise exception 'Access denied'; end if;
  select coalesce(c.financial_year_start,7) into fy_month from public.companies c where c.id=target_company;
  fy_start:=make_date(extract(year from as_of)::int-case when extract(month from as_of)::int<fy_month then 1 else 0 end,fy_month,1);
  return query
  with accounts_part as (
    select a.code ac,a.name an,a.type::text cat,
      case when a.type='asset' then coalesce(sum(case when e.id is not null then l.debit-l.credit else 0 end),0)
           else coalesce(sum(case when e.id is not null then l.credit-l.debit else 0 end),0) end amt
    from public.accounts a left join public.journal_lines l on l.account_id=a.id
    left join public.journal_entries e on e.id=l.entry_id and e.company_id=target_company
      and e.status in ('posted','reversed') and e.entry_date<=as_of
    where a.company_id=target_company and a.type in ('asset','liability','equity') group by a.id
  ), earnings as (
    select coalesce(sum(case when e.entry_date<fy_start then l.credit-l.debit else 0 end),0) prior,
           coalesce(sum(case when e.entry_date>=fy_start then l.credit-l.debit else 0 end),0) cur
    from public.journal_lines l join public.journal_entries e on e.id=l.entry_id
    join public.accounts a on a.id=l.account_id
    where e.company_id=target_company and e.status in ('posted','reversed') and e.entry_date<=as_of
      and a.type in ('income','expense')
  )
  select u.ac,u.an,u.cat,u.amt from (
    select ac,an,cat,amt,case cat when 'asset' then 1 when 'liability' then 2 else 3 end ord,0 sub from accounts_part
    union all select 'RE','Retained earnings (prior years)','equity',prior,3,1 from earnings
    union all select 'CYE','Current year earnings','equity',cur,3,2 from earnings
  ) u order by u.ord,u.sub,u.ac;
end; $$;

------------------------------------------------------------------ 2. Books lock
alter table public.companies
  add column if not exists books_locked_through date,
  add column if not exists books_locked_by uuid references auth.users(id),
  add column if not exists books_locked_at timestamptz;

create or replace function public.enforce_books_lock()
returns trigger language plpgsql security definer set search_path=public as $$
declare locked date; cid uuid;
begin
  cid:=case when tg_op='DELETE' then old.company_id else new.company_id end;
  select c.books_locked_through into locked from public.companies c where c.id=cid;
  if locked is not null then
    if (tg_op in ('UPDATE','DELETE') and old.status<>'draft' and old.entry_date<=locked)
       or (tg_op in ('INSERT','UPDATE') and new.status<>'draft' and new.entry_date<=locked) then
      raise exception 'The books are locked through %. Nothing dated on or before that day can be posted, changed or voided. Ask an owner or admin to move the lock date, or record a correcting entry after it.',to_char(locked,'DD Mon YYYY');
    end if;
  end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;
drop trigger if exists journal_entries_books_lock on public.journal_entries;
create trigger journal_entries_books_lock before insert or update or delete on public.journal_entries
  for each row execute function public.enforce_books_lock();

create or replace function public.set_books_lock(target_company uuid,lock_date date)
returns void language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null or not exists(select 1 from public.company_members m where m.company_id=target_company
     and m.user_id=auth.uid() and m.active and m.role in ('owner','admin')) then
    raise exception 'Only an owner or admin can lock or unlock the books';
  end if;
  if lock_date is not null and lock_date>current_date then raise exception 'The lock date cannot be in the future'; end if;
  update public.companies set books_locked_through=lock_date,books_locked_by=auth.uid(),books_locked_at=now() where id=target_company;
end; $$;
revoke all on function public.set_books_lock(uuid,date) from public,anon;
grant execute on function public.set_books_lock(uuid,date) to authenticated;

------------------------------------------------------------------ 3. Per-company document numbers
create table if not exists public.document_counters(
  company_id uuid not null references public.companies(id) on delete cascade,
  counter_key text not null,
  last_number bigint not null default 0,
  primary key(company_id,counter_key)
);
alter table public.document_counters enable row level security; -- only the numbering trigger touches it

create or replace function public.assign_company_document_number()
returns trigger language plpgsql security definer set search_path=public as $$
declare col text:=tg_argv[0]; ckey text:=tg_table_name; n bigint;
begin
  if tg_nargs>1 then ckey:=ckey||':'||coalesce(to_jsonb(new)->>tg_argv[1],''); end if;
  insert into public.document_counters(company_id,counter_key,last_number) values(new.company_id,ckey,1)
  on conflict(company_id,counter_key) do update set last_number=public.document_counters.last_number+1
  returning last_number into n;
  new:=jsonb_populate_record(new,jsonb_build_object(col,n));
  return new;
end; $$;

do $$
declare spec record; sql text;
begin
  for spec in select * from (values
    ('sales_invoices','invoice_number',null),('purchase_bills','bill_number',null),('payments','payment_number',null),
    ('journal_entries','entry_number',null),('quotations','quotation_number',null),('sales_orders','order_number',null),
    ('purchase_orders','order_number',null),('purchase_quotes','quote_number',null),('sales_credit_notes','credit_number',null),
    ('purchase_debit_notes','debit_number',null),('goods_document_drafts','document_number','kind')
  ) as t(tbl,col,kindcol) loop
    -- continue each company from its highest existing number
    if spec.kindcol is null then
      execute format('insert into public.document_counters(company_id,counter_key,last_number) select company_id,%L,max(%I) from public.%I group by company_id on conflict(company_id,counter_key) do update set last_number=greatest(public.document_counters.last_number,excluded.last_number)',spec.tbl,spec.col,spec.tbl);
      execute format('drop trigger if exists a0_assign_document_number on public.%I',spec.tbl);
      execute format('create trigger a0_assign_document_number before insert on public.%I for each row execute function public.assign_company_document_number(%L)',spec.tbl,spec.col);
    else
      execute format('insert into public.document_counters(company_id,counter_key,last_number) select company_id,%L||%L||%I,max(%I) from public.%I group by company_id,%I on conflict(company_id,counter_key) do update set last_number=greatest(public.document_counters.last_number,excluded.last_number)',spec.tbl,':',spec.kindcol,spec.col,spec.tbl,spec.kindcol);
      execute format('drop trigger if exists a0_assign_document_number on public.%I',spec.tbl);
      execute format('create trigger a0_assign_document_number before insert on public.%I for each row execute function public.assign_company_document_number(%L,%L)',spec.tbl,spec.col,spec.kindcol);
    end if;
  end loop;
end $$;

------------------------------------------------------------------ 4. Standard chart of accounts
create or replace function public.seed_standard_accounts(target_company uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  insert into public.accounts(company_id,code,name,type,system_account)
  select target_company,v.code,v.name,v.type::account_type,false from (values
    ('1300','Advances and Prepayments','asset'),('1310','Employee Advances and Loans','asset'),
    ('1400','Property, Plant and Equipment','asset'),('1410','Accumulated Depreciation','asset'),('1500','Security Deposits','asset'),
    ('2300','Accrued Expenses','liability'),('2400','Short-term Loans','liability'),('2500','Customer Advances','liability'),('2600','Long-term Loans','liability'),
    ('3100','Retained Earnings (opening balance)','equity'),('3200','Owner Drawings','equity'),
    ('4100','Sales Returns and Allowances','income'),('4200','Service Revenue','income'),('4900','Other Income','income'),('4910','Discount Received','income'),
    ('5100','Freight and Carriage Inward','expense'),('5200','Direct Labour','expense'),
    ('6010','Rent','expense'),('6020','Electricity, Gas and Water','expense'),('6030','Telephone and Internet','expense'),
    ('6040','Office Supplies and Stationery','expense'),('6050','Repairs and Maintenance','expense'),('6060','Fuel and Vehicle Running','expense'),
    ('6070','Travel and Conveyance','expense'),('6080','Advertising and Marketing','expense'),('6090','Professional and Legal Fees','expense'),
    ('6100','Insurance','expense'),('6110','Bank Charges','expense'),('6120','Depreciation Expense','expense'),('6130','Taxes, Duties and Licences','expense'),
    ('6140','Bad Debts','expense'),('6150','Discount Allowed','expense'),('6160','Interest and Finance Cost','expense'),('6900','Miscellaneous Expenses','expense')
  ) as v(code,name,type)
  on conflict(company_id,code) do nothing;
end; $$;
revoke all on function public.seed_standard_accounts(uuid) from public,anon,authenticated;

create or replace function public.seed_standard_accounts_trigger()
returns trigger language plpgsql security definer set search_path=public as $$
begin perform public.seed_standard_accounts(new.id); return new; end; $$;
drop trigger if exists companies_seed_standard_accounts on public.companies;
create trigger companies_seed_standard_accounts after insert on public.companies
  for each row execute function public.seed_standard_accounts_trigger();

select public.seed_standard_accounts(id) from public.companies;

commit;
