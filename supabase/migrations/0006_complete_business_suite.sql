-- CloudLedger PK: remaining production-suite schema in one migration.
-- Prerequisite: migrations 0001 through 0005 are already applied.

begin;

do $$ begin create type public.business_document_status as enum ('draft','approved','posted','part_paid','paid','void'); exception when duplicate_object then null; end $$;
do $$ begin create type public.payment_direction as enum ('receipt','payment'); exception when duplicate_object then null; end $$;
do $$ begin create type public.stock_movement_type as enum ('opening','purchase','sale','adjustment_in','adjustment_out','transfer_in','transfer_out','return_in','return_out'); exception when duplicate_object then null; end $$;
do $$ begin create type public.payroll_run_status as enum ('draft','approved','posted','paid','void'); exception when duplicate_object then null; end $$;
do $$ begin create type public.leave_request_status as enum ('pending','approved','rejected','cancelled'); exception when duplicate_object then null; end $$;

-- Add the reserved system accounts required by purchases, inventory and payroll.
insert into public.accounts(company_id,code,name,type,system_account)
select c.id,x.code,x.name,x.type::public.account_type,true from public.companies c cross join (values
  ('1150','Input GST','asset'),('1200','Inventory','asset'),('2050','Tax Payable','liability'),
  ('2200','Payroll Payable','liability'),('2210','EOBI Payable','liability'),('2220','SESSI Payable','liability'),
  ('6200','Salaries and Wages','expense'),('6210','Employer Contributions','expense')
) x(code,name,type) on conflict(company_id,code) do nothing;

create table if not exists public.tax_rates (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  name text not null, rate numeric(5,2) not null check(rate between 0 and 100), tax_kind text not null default 'gst',
  input_account_id uuid references public.accounts(id), output_account_id uuid references public.accounts(id),
  active boolean not null default true, effective_from date not null default current_date,
  effective_to date, created_at timestamptz not null default now(), unique(company_id,name,effective_from)
);

create table if not exists public.warehouses (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete restrict, code text not null, name text not null,
  active boolean not null default true, created_at timestamptz not null default now(), unique(company_id,code)
);

insert into public.warehouses(company_id,branch_id,code,name)
select b.company_id,b.id,'WH-'||b.code,b.name||' Warehouse' from public.branches b
on conflict(company_id,code) do nothing;

create table if not exists public.stock_movements (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  warehouse_id uuid not null references public.warehouses(id) on delete restrict, product_id uuid not null references public.products(id) on delete restrict,
  movement_type public.stock_movement_type not null, movement_date date not null default current_date,
  quantity numeric(18,3) not null check(quantity>0), unit_cost numeric(18,2) not null default 0 check(unit_cost>=0),
  source_type text, source_id uuid, reference text, notes text, created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.purchase_bills (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict, warehouse_id uuid references public.warehouses(id) on delete restrict,
  supplier_id uuid not null references public.contacts(id) on delete restrict, bill_number bigint generated always as identity,
  supplier_reference text, bill_date date not null, due_date date not null, notes text,
  status public.business_document_status not null default 'draft', subtotal numeric(18,2) not null default 0,
  gst_total numeric(18,2) not null default 0, total numeric(18,2) not null default 0, amount_paid numeric(18,2) not null default 0,
  journal_entry_id uuid references public.journal_entries(id), created_by uuid not null references auth.users(id),
  posted_at timestamptz, created_at timestamptz not null default now()
);

create table if not exists public.purchase_bill_lines (
  id uuid primary key default gen_random_uuid(), bill_id uuid not null references public.purchase_bills(id) on delete cascade,
  product_id uuid references public.products(id) on delete restrict, expense_account_id uuid references public.accounts(id) on delete restrict,
  description text not null, quantity numeric(18,3) not null check(quantity>0), unit_price numeric(18,2) not null check(unit_price>=0),
  gst_rate numeric(5,2) not null default 0 check(gst_rate between 0 and 100),
  subtotal numeric(18,2) generated always as (round(quantity*unit_price,2)) stored,
  gst_amount numeric(18,2) generated always as (round(quantity*unit_price*gst_rate/100,2)) stored,
  total numeric(18,2) generated always as (round(quantity*unit_price*(1+gst_rate/100),2)) stored,
  check(product_id is not null or expense_account_id is not null)
);

create table if not exists public.quotations (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  branch_id uuid not null references public.branches(id), customer_id uuid not null references public.contacts(id),
  quotation_number bigint generated always as identity, quotation_date date not null, valid_until date,
  status public.business_document_status not null default 'draft', notes text, subtotal numeric(18,2) not null default 0,
  gst_total numeric(18,2) not null default 0, total numeric(18,2) not null default 0,
  created_by uuid not null references auth.users(id), created_at timestamptz not null default now()
);

create table if not exists public.quotation_lines (
  id uuid primary key default gen_random_uuid(), quotation_id uuid not null references public.quotations(id) on delete cascade,
  product_id uuid references public.products(id), description text not null, quantity numeric(18,3) not null check(quantity>0),
  unit_price numeric(18,2) not null check(unit_price>=0), gst_rate numeric(5,2) not null default 0,
  subtotal numeric(18,2) generated always as (round(quantity*unit_price,2)) stored,
  gst_amount numeric(18,2) generated always as (round(quantity*unit_price*gst_rate/100,2)) stored,
  total numeric(18,2) generated always as (round(quantity*unit_price*(1+gst_rate/100),2)) stored
);

create table if not exists public.bank_accounts (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  branch_id uuid references public.branches(id), ledger_account_id uuid not null references public.accounts(id),
  name text not null, bank_name text, account_number text, iban text, opening_balance numeric(18,2) not null default 0,
  active boolean not null default true, created_at timestamptz not null default now(), unique(company_id,name)
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid not null references public.branches(id), contact_id uuid references public.contacts(id),
  bank_account_id uuid references public.bank_accounts(id), cash_account_id uuid references public.accounts(id),
  direction public.payment_direction not null, payment_number bigint generated always as identity,
  payment_date date not null, amount numeric(18,2) not null check(amount>0), reference text, notes text,
  sales_invoice_id uuid references public.sales_invoices(id), purchase_bill_id uuid references public.purchase_bills(id),
  status public.business_document_status not null default 'draft', journal_entry_id uuid references public.journal_entries(id),
  created_by uuid not null references auth.users(id), posted_at timestamptz, created_at timestamptz not null default now(),
  check((bank_account_id is not null) <> (cash_account_id is not null))
);

create table if not exists public.bank_statement_lines (
  id uuid primary key default gen_random_uuid(), bank_account_id uuid not null references public.bank_accounts(id) on delete cascade,
  transaction_date date not null, description text, reference text, debit numeric(18,2) not null default 0,
  credit numeric(18,2) not null default 0, matched_payment_id uuid references public.payments(id), reconciled boolean not null default false,
  created_at timestamptz not null default now(), check((debit>0 and credit=0) or (credit>0 and debit=0))
);

create table if not exists public.employees (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  branch_id uuid references public.branches(id), employee_code text not null, full_name text not null, father_name text,
  cnic text, phone text, email text, address text, designation text, department text, join_date date not null,
  base_salary numeric(18,2) not null default 0, eobi_enabled boolean not null default false, sessi_enabled boolean not null default false,
  tax_enabled boolean not null default false, monthly_income_tax numeric(18,2) not null default 0,
  monthly_eobi numeric(18,2) not null default 0, monthly_sessi numeric(18,2) not null default 0,
  active boolean not null default true, created_at timestamptz not null default now(),
  unique(company_id,employee_code)
);

create table if not exists public.attendance (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade, attendance_date date not null,
  check_in time, check_out time, status text not null default 'present', overtime_hours numeric(8,2) not null default 0,
  notes text, unique(employee_id,attendance_date)
);

create table if not exists public.leave_requests (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade, leave_type text not null,
  start_date date not null, end_date date not null, paid boolean not null default true,
  status public.leave_request_status not null default 'pending', reason text, approved_by uuid references auth.users(id),
  created_at timestamptz not null default now(), check(end_date>=start_date)
);

create table if not exists public.employee_salary_components (
  id uuid primary key default gen_random_uuid(), employee_id uuid not null references public.employees(id) on delete cascade,
  name text not null, component_type text not null check(component_type in ('allowance','deduction')),
  amount numeric(18,2) not null default 0, percentage numeric(5,2), active boolean not null default true
);

create table if not exists public.employee_loans (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id), loan_date date not null, principal numeric(18,2) not null check(principal>0),
  installment_amount numeric(18,2) not null check(installment_amount>0), recovered_amount numeric(18,2) not null default 0,
  notes text, active boolean not null default true
);

create table if not exists public.payroll_runs (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid references public.branches(id), period_start date not null, period_end date not null,
  status public.payroll_run_status not null default 'draft', gross_total numeric(18,2) not null default 0,
  deduction_total numeric(18,2) not null default 0, tax_total numeric(18,2) not null default 0,
  eobi_total numeric(18,2) not null default 0, sessi_total numeric(18,2) not null default 0,
  net_total numeric(18,2) not null default 0, journal_entry_id uuid references public.journal_entries(id),
  created_by uuid not null references auth.users(id), posted_at timestamptz, created_at timestamptz not null default now(),
  unique(company_id,branch_id,period_start,period_end), check(period_end>=period_start)
);

create table if not exists public.payroll_items (
  id uuid primary key default gen_random_uuid(), payroll_run_id uuid not null references public.payroll_runs(id) on delete cascade,
  employee_id uuid not null references public.employees(id), base_salary numeric(18,2) not null default 0,
  allowances numeric(18,2) not null default 0, overtime numeric(18,2) not null default 0,
  deductions numeric(18,2) not null default 0, loan_deduction numeric(18,2) not null default 0,
  income_tax numeric(18,2) not null default 0, eobi numeric(18,2) not null default 0, sessi numeric(18,2) not null default 0,
  gross_salary numeric(18,2) generated always as (base_salary+allowances+overtime) stored,
  net_salary numeric(18,2) generated always as (base_salary+allowances+overtime-deductions-loan_deduction-income_tax-eobi-sessi) stored,
  unique(payroll_run_id,employee_id)
);

create table if not exists public.role_templates (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  name text not null, permissions jsonb not null default '{}'::jsonb, created_at timestamptz not null default now(), unique(company_id,name)
);

create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  code text not null, name text not null, customer_id uuid references public.contacts(id), start_date date,
  end_date date, budget numeric(18,2), status text not null default 'active', notes text, unique(company_id,code)
);
create table if not exists public.cost_centers (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  code text not null, name text not null, active boolean not null default true, unique(company_id,code)
);
create table if not exists public.fixed_assets (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  branch_id uuid references public.branches(id), asset_code text not null, name text not null, purchase_date date not null,
  purchase_cost numeric(18,2) not null, useful_life_months integer not null check(useful_life_months>0),
  salvage_value numeric(18,2) not null default 0, accumulated_depreciation numeric(18,2) not null default 0,
  asset_account_id uuid references public.accounts(id), depreciation_account_id uuid references public.accounts(id),
  expense_account_id uuid references public.accounts(id), active boolean not null default true, unique(company_id,asset_code)
);
create table if not exists public.recurring_transactions (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  transaction_type text not null, frequency text not null, next_run_date date not null, end_date date,
  payload jsonb not null default '{}'::jsonb, active boolean not null default true, created_by uuid not null references auth.users(id)
);
create table if not exists public.fiscal_periods (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  name text not null, start_date date not null, end_date date not null, locked boolean not null default false,
  locked_by uuid references auth.users(id), locked_at timestamptz, unique(company_id,start_date,end_date), check(end_date>=start_date)
);
create table if not exists public.document_attachments (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  entity_type text not null, entity_id uuid not null, file_name text not null, storage_path text not null,
  mime_type text, file_size bigint, uploaded_by uuid not null references auth.users(id), created_at timestamptz not null default now()
);

create or replace function public.create_default_warehouse()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into warehouses(company_id,branch_id,code,name) values(new.company_id,new.id,'WH-'||new.code,new.name||' Warehouse')
  on conflict(company_id,code) do nothing; return new;
end; $$;
drop trigger if exists branch_default_warehouse on public.branches;
create trigger branch_default_warehouse after insert on public.branches for each row execute function public.create_default_warehouse();

-- Replace company onboarding so every future company receives the complete suite.
create or replace function public.create_company(company_name text)
returns uuid language plpgsql security definer set search_path=public as $$
declare new_company uuid; new_branch uuid; input_tax uuid; output_tax uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if length(trim(company_name))<2 then raise exception 'Company name is required'; end if;
  insert into companies(name,created_by) values(trim(company_name),auth.uid()) returning id into new_company;
  insert into company_members(company_id,user_id,role) values(new_company,auth.uid(),'owner');
  insert into branches(company_id,code,name) values(new_company,'HO','Head Office') returning id into new_branch;
  insert into accounts(company_id,code,name,type,system_account) values
    (new_company,'1000','Cash and Bank','asset',true),(new_company,'1100','Accounts Receivable','asset',true),
    (new_company,'1150','Input GST','asset',true),(new_company,'1200','Inventory','asset',true),
    (new_company,'2000','Accounts Payable','liability',true),(new_company,'2050','Tax Payable','liability',true),
    (new_company,'2100','GST Payable','liability',true),(new_company,'2200','Payroll Payable','liability',true),
    (new_company,'2210','EOBI Payable','liability',true),(new_company,'2220','SESSI Payable','liability',true),
    (new_company,'3000','Owner Equity','equity',true),(new_company,'4000','Sales','income',true),
    (new_company,'5000','Cost of Sales','expense',true),(new_company,'6000','Operating Expenses','expense',true),
    (new_company,'6200','Salaries and Wages','expense',true),(new_company,'6210','Employer Contributions','expense',true);
  select id into input_tax from accounts where company_id=new_company and code='1150';
  select id into output_tax from accounts where company_id=new_company and code='2100';
  insert into tax_rates(company_id,name,rate,tax_kind,input_account_id,output_account_id)
  values(new_company,'GST 18%',18,'gst',input_tax,output_tax);
  return new_company;
end; $$;

create or replace function public.apply_stock_movement()
returns trigger language plpgsql security definer set search_path=public as $$
declare multiplier numeric;
begin
  if not exists(select 1 from warehouses w where w.id=new.warehouse_id and w.company_id=new.company_id) then raise exception 'Warehouse does not belong to company'; end if;
  if not exists(select 1 from products p where p.id=new.product_id and p.company_id=new.company_id and not p.is_service) then raise exception 'Invalid stock product'; end if;
  multiplier:=case when new.movement_type in ('opening','purchase','adjustment_in','transfer_in','return_in') then 1 else -1 end;
  update products set quantity_on_hand=quantity_on_hand+(new.quantity*multiplier) where id=new.product_id;
  if (select quantity_on_hand from products where id=new.product_id)<0 then raise exception 'Insufficient stock'; end if;
  return new;
end; $$;
drop trigger if exists stock_movement_apply on public.stock_movements;
create trigger stock_movement_apply after insert on public.stock_movements for each row execute function public.apply_stock_movement();

create or replace function public.record_stock_adjustment(target_company uuid,target_warehouse uuid,target_product uuid,target_quantity numeric,target_increase boolean,target_reference text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare new_id uuid;
begin
  if not can_write_company(target_company) then raise exception 'Access denied'; end if;
  if target_quantity<=0 then raise exception 'Quantity must be greater than zero'; end if;
  insert into stock_movements(company_id,warehouse_id,product_id,movement_type,quantity,reference,created_by)
  values(target_company,target_warehouse,target_product,case when target_increase then 'adjustment_in'::stock_movement_type else 'adjustment_out'::stock_movement_type end,target_quantity,target_reference,auth.uid()) returning id into new_id;
  return new_id;
end; $$;

create or replace function public.post_purchase_bill(target_bill uuid)
returns void language plpgsql security definer set search_path=public as $$
declare bill purchase_bills%rowtype; sub numeric(18,2); tax numeric(18,2); grand numeric(18,2);
  ap_account uuid; inventory_account uuid; input_tax_account uuid; new_journal uuid; line record;
begin
  select * into bill from purchase_bills where id=target_bill and status='draft' for update;
  if bill.id is null or not can_write_company(bill.company_id) then raise exception 'Bill not found or access denied'; end if;
  if not exists(select 1 from contacts where id=bill.supplier_id and company_id=bill.company_id and kind in ('supplier','both') and active) then raise exception 'Invalid supplier'; end if;
  if not exists(select 1 from branches where id=bill.branch_id and company_id=bill.company_id and active) then raise exception 'Invalid branch'; end if;
  if bill.warehouse_id is not null and not exists(select 1 from warehouses where id=bill.warehouse_id and company_id=bill.company_id and branch_id=bill.branch_id and active) then raise exception 'Invalid warehouse'; end if;
  if exists(select 1 from purchase_bill_lines l join products p on p.id=l.product_id where l.bill_id=bill.id and p.company_id<>bill.company_id) then raise exception 'Invalid product company'; end if;
  if exists(select 1 from purchase_bill_lines l join accounts a on a.id=l.expense_account_id where l.bill_id=bill.id and a.company_id<>bill.company_id) then raise exception 'Invalid expense account'; end if;
  if exists(select 1 from purchase_bill_lines l left join products p on p.id=l.product_id where l.bill_id=bill.id and (l.product_id is null or p.is_service) and l.expense_account_id is null) then raise exception 'Expense account is required for non-stock lines'; end if;
  if exists(select 1 from purchase_bill_lines l join products p on p.id=l.product_id where l.bill_id=bill.id and not p.is_service) and bill.warehouse_id is null then raise exception 'Warehouse is required for stock purchases'; end if;
  select coalesce(sum(subtotal),0),coalesce(sum(gst_amount),0),coalesce(sum(total),0) into sub,tax,grand from purchase_bill_lines where bill_id=bill.id;
  if grand<=0 then raise exception 'Bill requires at least one line'; end if;
  select id into ap_account from accounts where company_id=bill.company_id and code='2000';
  select id into inventory_account from accounts where company_id=bill.company_id and code='1200';
  select id into input_tax_account from accounts where company_id=bill.company_id and code='1150';
  if ap_account is null or inventory_account is null or (tax>0 and input_tax_account is null) then raise exception 'Required system accounts are missing'; end if;
  insert into journal_entries(company_id,branch_id,entry_date,reference,description,created_by)
  values(bill.company_id,bill.branch_id,bill.bill_date,'BILL-'||lpad(bill.bill_number::text,6,'0'),'Supplier bill',auth.uid()) returning id into new_journal;
  insert into journal_lines(entry_id,account_id,description,debit,credit)
  select new_journal,coalesce(l.expense_account_id,inventory_account),l.description,sum(l.subtotal),0 from purchase_bill_lines l where l.bill_id=bill.id group by coalesce(l.expense_account_id,inventory_account),l.description;
  if tax>0 then insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,input_tax_account,'Input GST',tax,0); end if;
  insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,ap_account,'Supplier payable',0,grand);
  perform post_journal(new_journal);
  update purchase_bills set subtotal=sub,gst_total=tax,total=grand,status='posted',journal_entry_id=new_journal,posted_at=now() where id=bill.id;
  if bill.warehouse_id is not null then
    for line in select l.product_id,l.quantity,l.unit_price from purchase_bill_lines l join products p on p.id=l.product_id where l.bill_id=bill.id and not p.is_service loop
      insert into stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,created_by)
      values(bill.company_id,bill.warehouse_id,line.product_id,'purchase',bill.bill_date,line.quantity,line.unit_price,'purchase_bill',bill.id,auth.uid());
    end loop;
  end if;
end; $$;

create or replace function public.post_payment(target_payment uuid)
returns void language plpgsql security definer set search_path=public as $$
declare p payments%rowtype; money_account uuid; control_account uuid; new_journal uuid; remaining numeric(18,2);
begin
  select * into p from payments where id=target_payment and status='draft' for update;
  if p.id is null or not can_write_company(p.company_id) then raise exception 'Payment not found or access denied'; end if;
  select coalesce(px.cash_account_id,b.ledger_account_id) into money_account from payments px left join bank_accounts b on b.id=px.bank_account_id where px.id=p.id;
  if money_account is null then raise exception 'Cash or bank account is required'; end if;
  if not exists(select 1 from accounts a where a.id=money_account and a.company_id=p.company_id and a.active) then raise exception 'Invalid cash or bank ledger account'; end if;
  if p.direction='receipt' then
    select id into control_account from accounts where company_id=p.company_id and code='1100';
  else select id into control_account from accounts where company_id=p.company_id and code='2000'; end if;
  insert into journal_entries(company_id,branch_id,entry_date,reference,description,created_by)
  values(p.company_id,p.branch_id,p.payment_date,'PAY-'||lpad(p.payment_number::text,6,'0'),case when p.direction='receipt' then 'Customer receipt' else 'Supplier payment' end,auth.uid()) returning id into new_journal;
  if p.direction='receipt' then
    insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,money_account,'Money received',p.amount,0),(new_journal,control_account,'Receivable settled',0,p.amount);
    if p.sales_invoice_id is not null then
      if not exists(select 1 from sales_invoices where id=p.sales_invoice_id and company_id=p.company_id and status='posted' and total-amount_paid>=p.amount) then raise exception 'Invalid invoice or payment exceeds amount due'; end if;
      update sales_invoices set amount_paid=amount_paid+p.amount where id=p.sales_invoice_id returning total-amount_paid into remaining;
      if remaining<=0 then update sales_invoices set status='paid' where id=p.sales_invoice_id; end if;
    end if;
  else
    insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,control_account,'Payable settled',p.amount,0),(new_journal,money_account,'Money paid',0,p.amount);
    if p.purchase_bill_id is not null then
      if not exists(select 1 from purchase_bills where id=p.purchase_bill_id and company_id=p.company_id and status in ('posted','part_paid') and total-amount_paid>=p.amount) then raise exception 'Invalid bill or payment exceeds amount due'; end if;
      update purchase_bills set amount_paid=amount_paid+p.amount,status=case when amount_paid+p.amount>=total then 'paid'::business_document_status else 'part_paid'::business_document_status end where id=p.purchase_bill_id returning total-amount_paid into remaining;
    end if;
  end if;
  perform post_journal(new_journal);
  update payments set status='posted',journal_entry_id=new_journal,posted_at=now() where id=p.id;
end; $$;

create or replace function public.prepare_payroll_run(target_run uuid)
returns void language plpgsql security definer set search_path=public as $$
declare r payroll_runs%rowtype;
begin
  select * into r from payroll_runs where id=target_run and status='draft' for update;
  if r.id is null or not can_write_company(r.company_id) then raise exception 'Payroll run not found or access denied'; end if;
  delete from payroll_items where payroll_run_id=r.id;
  insert into payroll_items(payroll_run_id,employee_id,base_salary,allowances,deductions,loan_deduction,income_tax,eobi,sessi)
  select r.id,e.id,e.base_salary,
    coalesce((select sum(case when component_type='allowance' then coalesce(amount,e.base_salary*percentage/100) else 0 end) from employee_salary_components c where c.employee_id=e.id and c.active),0),
    coalesce((select sum(case when component_type='deduction' then coalesce(amount,e.base_salary*percentage/100) else 0 end) from employee_salary_components c where c.employee_id=e.id and c.active),0),
    coalesce((select least(installment_amount,principal-recovered_amount) from employee_loans l where l.employee_id=e.id and l.active order by loan_date limit 1),0),
    case when e.tax_enabled then e.monthly_income_tax else 0 end,
    case when e.eobi_enabled then e.monthly_eobi else 0 end,
    case when e.sessi_enabled then e.monthly_sessi else 0 end
  from employees e where e.company_id=r.company_id and e.active and (r.branch_id is null or e.branch_id=r.branch_id);
  update payroll_runs pr set
    gross_total=x.gross,deduction_total=x.deductions,tax_total=x.tax,eobi_total=x.eobi,sessi_total=x.sessi,net_total=x.net
  from (select coalesce(sum(gross_salary),0) gross,coalesce(sum(deductions+loan_deduction),0) deductions,coalesce(sum(income_tax),0) tax,coalesce(sum(eobi),0) eobi,coalesce(sum(sessi),0) sessi,coalesce(sum(net_salary),0) net from payroll_items where payroll_run_id=r.id) x where pr.id=r.id;
end; $$;

create or replace function public.post_payroll_run(target_run uuid)
returns void language plpgsql security definer set search_path=public as $$
declare r payroll_runs%rowtype; salary_expense uuid; payroll_payable uuid; tax_payable uuid; eobi_payable uuid; sessi_payable uuid; new_journal uuid;
begin
  select * into r from payroll_runs where id=target_run and status='draft' for update;
  if r.id is null or not can_write_company(r.company_id) then raise exception 'Payroll run not found or access denied'; end if;
  if not exists(select 1 from payroll_items where payroll_run_id=r.id) then perform prepare_payroll_run(target_run); end if;
  update payroll_runs pr set gross_total=x.gross,deduction_total=x.deductions,tax_total=x.tax,eobi_total=x.eobi,sessi_total=x.sessi,net_total=x.net
  from (select coalesce(sum(gross_salary),0) gross,coalesce(sum(deductions+loan_deduction),0) deductions,coalesce(sum(income_tax),0) tax,coalesce(sum(eobi),0) eobi,coalesce(sum(sessi),0) sessi,coalesce(sum(net_salary),0) net from payroll_items where payroll_run_id=r.id) x where pr.id=r.id;
  select * into r from payroll_runs where id=target_run;
  if r.gross_total<=0 then raise exception 'Payroll run has no payable employees'; end if;
  select id into salary_expense from accounts where company_id=r.company_id and code='6200';
  select id into payroll_payable from accounts where company_id=r.company_id and code='2200';
  select id into tax_payable from accounts where company_id=r.company_id and code='2050';
  select id into eobi_payable from accounts where company_id=r.company_id and code='2210';
  select id into sessi_payable from accounts where company_id=r.company_id and code='2220';
  insert into journal_entries(company_id,branch_id,entry_date,reference,description,created_by) values(r.company_id,r.branch_id,r.period_end,'PAYROLL-'||to_char(r.period_end,'YYYYMM'),'Monthly payroll',auth.uid()) returning id into new_journal;
  insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,salary_expense,'Gross payroll',r.gross_total,0),(new_journal,payroll_payable,'Net salaries payable',0,r.net_total);
  if r.deduction_total>0 then insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,payroll_payable,'Other deductions',0,r.deduction_total); end if;
  if r.tax_total>0 then insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,tax_payable,'Salary tax',0,r.tax_total); end if;
  if r.eobi_total>0 then insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,eobi_payable,'EOBI',0,r.eobi_total); end if;
  if r.sessi_total>0 then insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,sessi_payable,'SESSI',0,r.sessi_total); end if;
  perform post_journal(new_journal); update payroll_runs set status='posted',journal_entry_id=new_journal,posted_at=now() where id=r.id;
end; $$;

-- Allow receipts to update only payment fields of an otherwise immutable sales invoice.
create or replace function public.protect_posted_invoice()
returns trigger language plpgsql as $$
begin
  if tg_op='DELETE' and old.status in ('posted','paid','void') then raise exception 'Posted invoices are immutable'; end if;
  if tg_op='UPDATE' and old.status in ('posted','paid','void') then
    if (to_jsonb(new)-'amount_paid'-'status')=(to_jsonb(old)-'amount_paid'-'status')
      and new.amount_paid>=old.amount_paid and new.status in ('posted','paid') then return new; end if;
    raise exception 'Posted invoices are immutable except for payment allocation';
  end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;

create or replace function public.protect_posted_business_document()
returns trigger language plpgsql as $$
begin
  if tg_op='DELETE' and old.status not in ('draft','approved') then raise exception 'Posted document is immutable'; end if;
  if tg_op='UPDATE' and old.status not in ('draft','approved') then
    if tg_table_name='purchase_bills' and (to_jsonb(new)-'amount_paid'-'status')=(to_jsonb(old)-'amount_paid'-'status')
      and new.amount_paid>=old.amount_paid and new.status in ('posted','part_paid','paid') then return new; end if;
    raise exception 'Posted document is immutable';
  end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;
drop trigger if exists purchase_bill_immutable on public.purchase_bills;
create trigger purchase_bill_immutable before update or delete on public.purchase_bills for each row execute function public.protect_posted_business_document();
drop trigger if exists payment_immutable on public.payments;
create trigger payment_immutable before update or delete on public.payments for each row execute function public.protect_posted_business_document();
drop trigger if exists payroll_run_immutable on public.payroll_runs;
create trigger payroll_run_immutable before update or delete on public.payroll_runs for each row execute function public.protect_posted_business_document();

create or replace function public.protect_purchase_bill_lines()
returns trigger language plpgsql as $$
declare parent_status public.business_document_status;
begin
  select status into parent_status from purchase_bills where id=coalesce(new.bill_id,old.bill_id);
  if parent_status not in ('draft','approved') then raise exception 'Posted bill lines are immutable'; end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;
drop trigger if exists purchase_bill_lines_immutable on public.purchase_bill_lines;
create trigger purchase_bill_lines_immutable before insert or update or delete on public.purchase_bill_lines for each row execute function public.protect_purchase_bill_lines();

-- Replace sales posting so product invoices also reduce stock.
create or replace function public.post_sales_invoice(target_invoice uuid)
returns void language plpgsql security definer set search_path=public as $$
declare inv sales_invoices%rowtype; sub numeric(18,2); tax numeric(18,2); grand numeric(18,2);
  ar_account uuid; sales_account uuid; gst_account uuid; inventory_account uuid; cogs_account uuid; new_journal uuid; target_warehouse uuid; line record; cogs_total numeric(18,2);
begin
  select * into inv from sales_invoices where id=target_invoice and status='draft' for update;
  if inv.id is null or not can_write_company(inv.company_id) then raise exception 'Invoice not found or access denied'; end if;
  if not exists(select 1 from contacts where id=inv.customer_id and company_id=inv.company_id and kind in ('customer','both') and active) then raise exception 'Invalid customer'; end if;
  if not exists(select 1 from branches where id=inv.branch_id and company_id=inv.company_id and active) then raise exception 'Invalid branch'; end if;
  if exists(select 1 from sales_invoice_lines l join products p on p.id=l.product_id where l.invoice_id=inv.id and p.company_id<>inv.company_id) then raise exception 'Invalid product company'; end if;
  select coalesce(sum(subtotal),0),coalesce(sum(gst_amount),0),coalesce(sum(total),0) into sub,tax,grand from sales_invoice_lines where invoice_id=inv.id;
  if grand<=0 then raise exception 'Invoice requires at least one line'; end if;
  select id into ar_account from accounts where company_id=inv.company_id and code='1100';
  select id into sales_account from accounts where company_id=inv.company_id and code='4000';
  select id into gst_account from accounts where company_id=inv.company_id and code='2100';
  select id into inventory_account from accounts where company_id=inv.company_id and code='1200';
  select id into cogs_account from accounts where company_id=inv.company_id and code='5000';
  select coalesce(sum(l.quantity*p.purchase_price),0) into cogs_total from sales_invoice_lines l join products p on p.id=l.product_id where l.invoice_id=inv.id and not p.is_service;
  if ar_account is null or sales_account is null or (tax>0 and gst_account is null) or (cogs_total>0 and (inventory_account is null or cogs_account is null)) then raise exception 'Required system accounts are missing'; end if;
  insert into journal_entries(company_id,branch_id,entry_date,reference,description,created_by)
  values(inv.company_id,inv.branch_id,inv.invoice_date,'INV-'||lpad(inv.invoice_number::text,6,'0'),'Sales invoice',auth.uid()) returning id into new_journal;
  insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,ar_account,'Customer receivable',grand,0),(new_journal,sales_account,'Sales revenue',0,sub);
  if tax>0 then insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,gst_account,'Output GST',0,tax); end if;
  if cogs_total>0 then insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,cogs_account,'Cost of goods sold',cogs_total,0),(new_journal,inventory_account,'Inventory issued',0,cogs_total); end if;
  perform post_journal(new_journal);
  update sales_invoices set subtotal=sub,gst_total=tax,total=grand,status='posted',journal_entry_id=new_journal,posted_at=now() where id=inv.id;
  select id into target_warehouse from warehouses where company_id=inv.company_id and branch_id=inv.branch_id and active order by created_at limit 1;
  for line in select l.product_id,l.quantity,p.purchase_price,p.is_service from sales_invoice_lines l join products p on p.id=l.product_id where l.invoice_id=inv.id and l.product_id is not null loop
    if not line.is_service then
      if target_warehouse is null then raise exception 'Branch warehouse is missing'; end if;
      insert into stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,created_by)
      values(inv.company_id,target_warehouse,line.product_id,'sale',inv.invoice_date,line.quantity,line.purchase_price,'sales_invoice',inv.id,auth.uid());
    end if;
  end loop;
end; $$;

create or replace function public.get_trial_balance(target_company uuid,date_from date default null,date_to date default current_date)
returns table(account_code text,account_name text,account_type public.account_type,debit numeric,credit numeric,balance numeric)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_company_member(target_company) then raise exception 'Access denied'; end if;
  return query select a.code,a.name,a.type,
    coalesce(sum(case when e.id is not null then l.debit else 0 end),0),
    coalesce(sum(case when e.id is not null then l.credit else 0 end),0),
    case when a.type in ('asset','expense') then coalesce(sum(case when e.id is not null then l.debit-l.credit else 0 end),0) else coalesce(sum(case when e.id is not null then l.credit-l.debit else 0 end),0) end
  from accounts a left join journal_lines l on l.account_id=a.id left join journal_entries e on e.id=l.entry_id and e.status='posted'
  and (date_from is null or e.entry_date>=date_from) and e.entry_date<=date_to
  where a.company_id=target_company group by a.id order by a.code;
end; $$;

create or replace function public.get_general_ledger(target_company uuid,date_from date,date_to date)
returns table(entry_date date,reference text,description text,account_code text,account_name text,debit numeric,credit numeric,running_balance numeric)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_company_member(target_company) then raise exception 'Access denied'; end if;
  return query select e.entry_date,e.reference,coalesce(l.description,e.description),a.code,a.name,l.debit,l.credit,
    sum(case when a.type in ('asset','expense') then l.debit-l.credit else l.credit-l.debit end) over(partition by a.id order by e.entry_date,e.entry_number,l.id)
  from journal_entries e join journal_lines l on l.entry_id=e.id join accounts a on a.id=l.account_id
  where e.company_id=target_company and e.status='posted' and e.entry_date between date_from and date_to order by e.entry_date,e.entry_number;
end; $$;

create or replace function public.get_profit_loss(target_company uuid,date_from date,date_to date)
returns table(account_code text,account_name text,category text,amount numeric)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_company_member(target_company) then raise exception 'Access denied'; end if;
  return query select a.code,a.name,a.type::text,
    case when a.type='income' then coalesce(sum(case when e.id is not null then l.credit-l.debit else 0 end),0) else coalesce(sum(case when e.id is not null then l.debit-l.credit else 0 end),0) end
  from accounts a left join journal_lines l on l.account_id=a.id left join journal_entries e on e.id=l.entry_id and e.status='posted' and e.entry_date between date_from and date_to
  where a.company_id=target_company and a.type in ('income','expense') group by a.id order by a.type,a.code;
end; $$;

create or replace function public.get_balance_sheet(target_company uuid,as_of date default current_date)
returns table(account_code text,account_name text,category text,amount numeric)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_company_member(target_company) then raise exception 'Access denied'; end if;
  return query select a.code,a.name,a.type::text,
    case when a.type='asset' then coalesce(sum(case when e.id is not null then l.debit-l.credit else 0 end),0) else coalesce(sum(case when e.id is not null then l.credit-l.debit else 0 end),0) end
  from accounts a left join journal_lines l on l.account_id=a.id left join journal_entries e on e.id=l.entry_id and e.status='posted' and e.entry_date<=as_of
  where a.company_id=target_company and a.type in ('asset','liability','equity') group by a.id order by a.type,a.code;
end; $$;

create or replace function public.get_receivable_aging(target_company uuid,as_of date default current_date)
returns table(contact_name text,current_amount numeric,days_1_30 numeric,days_31_60 numeric,days_61_90 numeric,days_over_90 numeric,total_due numeric)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_company_member(target_company) then raise exception 'Access denied'; end if;
  return query select c.name,
    sum(case when as_of-i.due_date<=0 then i.total-i.amount_paid else 0 end),sum(case when as_of-i.due_date between 1 and 30 then i.total-i.amount_paid else 0 end),
    sum(case when as_of-i.due_date between 31 and 60 then i.total-i.amount_paid else 0 end),sum(case when as_of-i.due_date between 61 and 90 then i.total-i.amount_paid else 0 end),
    sum(case when as_of-i.due_date>90 then i.total-i.amount_paid else 0 end),sum(i.total-i.amount_paid)
  from sales_invoices i join contacts c on c.id=i.customer_id where i.company_id=target_company and i.status in ('posted','paid') and i.total>i.amount_paid group by c.id,c.name;
end; $$;

create or replace function public.get_payable_aging(target_company uuid,as_of date default current_date)
returns table(contact_name text,current_amount numeric,days_1_30 numeric,days_31_60 numeric,days_61_90 numeric,days_over_90 numeric,total_due numeric)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_company_member(target_company) then raise exception 'Access denied'; end if;
  return query select c.name,
    sum(case when as_of-b.due_date<=0 then b.total-b.amount_paid else 0 end),sum(case when as_of-b.due_date between 1 and 30 then b.total-b.amount_paid else 0 end),
    sum(case when as_of-b.due_date between 31 and 60 then b.total-b.amount_paid else 0 end),sum(case when as_of-b.due_date between 61 and 90 then b.total-b.amount_paid else 0 end),
    sum(case when as_of-b.due_date>90 then b.total-b.amount_paid else 0 end),sum(b.total-b.amount_paid)
  from purchase_bills b join contacts c on c.id=b.supplier_id where b.company_id=target_company and b.status in ('posted','part_paid','paid') and b.total>b.amount_paid group by c.id,c.name;
end; $$;

-- Tenant isolation: members can read their company, accounting writers can mutate it.
do $$
declare t text;
begin
  foreach t in array array['tax_rates','warehouses','stock_movements','purchase_bills','quotations','bank_accounts','payments','employees','attendance','leave_requests','employee_loans','payroll_runs','role_templates','projects','cost_centers','fixed_assets','recurring_transactions','fiscal_periods','document_attachments'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('create policy %I on public.%I for select using(public.is_company_member(company_id))','members_read_'||t,t);
    execute format('create policy %I on public.%I for all using(public.can_write_company(company_id)) with check(public.can_write_company(company_id))','writers_manage_'||t,t);
  end loop;
end $$;

alter table public.purchase_bill_lines enable row level security;
create policy "members read purchase lines" on public.purchase_bill_lines for select using(exists(select 1 from purchase_bills b where b.id=bill_id and is_company_member(b.company_id)));
create policy "writers manage purchase lines" on public.purchase_bill_lines for all using(exists(select 1 from purchase_bills b where b.id=bill_id and can_write_company(b.company_id))) with check(exists(select 1 from purchase_bills b where b.id=bill_id and can_write_company(b.company_id)));
alter table public.quotation_lines enable row level security;
create policy "members read quotation lines" on public.quotation_lines for select using(exists(select 1 from quotations q where q.id=quotation_id and is_company_member(q.company_id)));
create policy "writers manage quotation lines" on public.quotation_lines for all using(exists(select 1 from quotations q where q.id=quotation_id and can_write_company(q.company_id))) with check(exists(select 1 from quotations q where q.id=quotation_id and can_write_company(q.company_id)));
alter table public.employee_salary_components enable row level security;
create policy "members read salary components" on public.employee_salary_components for select using(exists(select 1 from employees e where e.id=employee_id and is_company_member(e.company_id)));
create policy "writers manage salary components" on public.employee_salary_components for all using(exists(select 1 from employees e where e.id=employee_id and can_write_company(e.company_id))) with check(exists(select 1 from employees e where e.id=employee_id and can_write_company(e.company_id)));
alter table public.payroll_items enable row level security;
create policy "members read payroll items" on public.payroll_items for select using(exists(select 1 from payroll_runs r where r.id=payroll_run_id and is_company_member(r.company_id)));
create policy "writers manage payroll items" on public.payroll_items for all using(exists(select 1 from payroll_runs r where r.id=payroll_run_id and can_write_company(r.company_id))) with check(exists(select 1 from payroll_runs r where r.id=payroll_run_id and can_write_company(r.company_id)));
alter table public.bank_statement_lines enable row level security;
create policy "members read statements" on public.bank_statement_lines for select using(exists(select 1 from bank_accounts b where b.id=bank_account_id and is_company_member(b.company_id)));
create policy "writers manage statements" on public.bank_statement_lines for all using(exists(select 1 from bank_accounts b where b.id=bank_account_id and can_write_company(b.company_id))) with check(exists(select 1 from bank_accounts b where b.id=bank_account_id and can_write_company(b.company_id)));

create or replace function public.write_audit_log()
returns trigger language plpgsql security definer set search_path=public as $$
declare cid uuid; eid text;
begin
  cid:=coalesce((to_jsonb(new)->>'company_id')::uuid,(to_jsonb(old)->>'company_id')::uuid);
  eid:=coalesce(to_jsonb(new)->>'id',to_jsonb(old)->>'id');
  insert into audit_log(company_id,user_id,action,entity_type,entity_id,old_values,new_values)
  values(cid,auth.uid(),tg_op,tg_table_name,eid,case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end);
  return case when tg_op='DELETE' then old else new end;
end; $$;
drop trigger if exists purchase_bill_audit on public.purchase_bills;
create trigger purchase_bill_audit after insert or update or delete on public.purchase_bills for each row execute function public.write_audit_log();
drop trigger if exists payment_audit on public.payments;
create trigger payment_audit after insert or update or delete on public.payments for each row execute function public.write_audit_log();
drop trigger if exists payroll_audit on public.payroll_runs;
create trigger payroll_audit after insert or update or delete on public.payroll_runs for each row execute function public.write_audit_log();

grant execute on function public.record_stock_adjustment(uuid,uuid,uuid,numeric,boolean,text) to authenticated;
grant execute on function public.post_purchase_bill(uuid) to authenticated;
grant execute on function public.post_payment(uuid) to authenticated;
grant execute on function public.prepare_payroll_run(uuid) to authenticated;
grant execute on function public.post_payroll_run(uuid) to authenticated;
grant execute on function public.get_trial_balance(uuid,date,date) to authenticated;
grant execute on function public.get_general_ledger(uuid,date,date) to authenticated;
grant execute on function public.get_profit_loss(uuid,date,date) to authenticated;
grant execute on function public.get_balance_sheet(uuid,date) to authenticated;
grant execute on function public.get_receivable_aging(uuid,date) to authenticated;
grant execute on function public.get_payable_aging(uuid,date) to authenticated;

-- Seed common Pakistan GST rates without hard-coding them into application logic.
insert into public.tax_rates(company_id,name,rate,tax_kind,input_account_id,output_account_id)
select c.id,'GST 18%',18,'gst',ia.id,oa.id from companies c
join accounts ia on ia.company_id=c.id and ia.code='1150' join accounts oa on oa.company_id=c.id and oa.code='2100'
on conflict(company_id,name,effective_from) do nothing;

commit;
