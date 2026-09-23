-- Bank statement imports and controlled reconciliation.
-- Statement mutations are restricted to audited security-definer functions.

begin;

create table public.bank_statement_imports (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  bank_account_id uuid not null references public.bank_accounts(id) on delete cascade,
  file_name text not null,
  row_count integer not null check(row_count>=0),
  inserted_count integer not null default 0 check(inserted_count>=0),
  duplicate_count integer not null default 0 check(duplicate_count>=0),
  imported_by uuid not null references auth.users(id),
  imported_at timestamptz not null default now()
);

create table public.bank_reconciliation_log (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  bank_account_id uuid not null references public.bank_accounts(id) on delete cascade,
  statement_line_id uuid not null references public.bank_statement_lines(id) on delete restrict,
  payment_id uuid references public.payments(id) on delete restrict,
  action text not null check(action in ('reconciled','unreconciled')),
  reason text,
  performed_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

alter table public.bank_statement_lines
  add column import_batch_id uuid references public.bank_statement_imports(id) on delete restrict,
  add column external_id text,
  add column source_row integer,
  add column fingerprint text,
  add column reconciled_at timestamptz,
  add column reconciled_by uuid references auth.users(id);

update public.bank_statement_lines set fingerprint='legacy:'||id::text where fingerprint is null;
alter table public.bank_statement_lines alter column fingerprint set not null;
create unique index bank_statement_line_fingerprint_uq on public.bank_statement_lines(bank_account_id,fingerprint);
create index bank_statement_lines_unreconciled_idx on public.bank_statement_lines(bank_account_id,transaction_date) where not reconciled;
create index payments_bank_match_idx on public.payments(bank_account_id,payment_date,amount) where status='posted';

alter table public.bank_statement_imports enable row level security;
alter table public.bank_reconciliation_log enable row level security;
create policy "members read statement imports" on public.bank_statement_imports for select using(public.is_company_member(company_id));
create policy "members read reconciliation log" on public.bank_reconciliation_log for select using(public.is_company_member(company_id));

-- Remove direct statement writes. Import/match functions below perform validated writes.
drop policy if exists "writers manage statements" on public.bank_statement_lines;

create or replace function public.import_bank_statement(target_bank uuid,target_file_name text,target_lines jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare target_company uuid; batch_id uuid; requested integer; inserted integer; item jsonb;
  line_date date; line_debit numeric(18,2); line_credit numeric(18,2); line_row integer; line_external text; line_fingerprint text;
begin
  select company_id into target_company from bank_accounts where id=target_bank and active for update;
  if target_company is null or not can_write_company(target_company) then raise exception 'Active bank account not found or access denied'; end if;
  if jsonb_typeof(target_lines)<>'array' then raise exception 'Statement lines must be an array'; end if;
  requested:=jsonb_array_length(target_lines);
  if requested=0 or requested>2000 then raise exception 'Import must contain between 1 and 2000 rows'; end if;
  if nullif(trim(target_file_name),'') is null then raise exception 'File name is required'; end if;
  insert into bank_statement_imports(company_id,bank_account_id,file_name,row_count,imported_by)
  values(target_company,target_bank,left(trim(target_file_name),255),requested,auth.uid()) returning id into batch_id;
  inserted:=0;
  for item in select value from jsonb_array_elements(target_lines) loop
    begin
      line_date:=(item->>'transaction_date')::date;
      line_debit:=round(coalesce(nullif(item->>'debit','')::numeric,0),2);
      line_credit:=round(coalesce(nullif(item->>'credit','')::numeric,0),2);
      line_row:=nullif(item->>'source_row','')::integer;
      line_external:=nullif(left(trim(coalesce(item->>'external_id','')),120),'');
    exception when others then raise exception 'Invalid statement row %',coalesce(item->>'source_row','?'); end;
    if line_date is null or line_row is null or line_row<1 or not ((line_debit>0 and line_credit=0) or (line_credit>0 and line_debit=0)) then
      raise exception 'Row % must have a date and exactly one positive debit or credit',line_row;
    end if;
    line_fingerprint:=md5(target_bank::text||'|'||case when line_external is not null then 'id:'||line_external else 'row:'||line_date::text||'|'||lower(trim(coalesce(item->>'description','')))||'|'||lower(trim(coalesce(item->>'reference','')))||'|'||line_debit::text||'|'||line_credit::text||'|'||line_row::text end);
    insert into bank_statement_lines(bank_account_id,transaction_date,description,reference,debit,credit,import_batch_id,external_id,source_row,fingerprint)
    values(target_bank,line_date,nullif(trim(item->>'description'),''),nullif(trim(item->>'reference'),''),line_debit,line_credit,batch_id,line_external,line_row,line_fingerprint)
    on conflict(bank_account_id,fingerprint) do nothing;
    if found then inserted:=inserted+1; end if;
  end loop;
  update bank_statement_imports set inserted_count=inserted,duplicate_count=requested-inserted where id=batch_id;
  return jsonb_build_object('batch_id',batch_id,'row_count',requested,'inserted_count',inserted,'duplicate_count',requested-inserted);
end; $$;

create or replace function public.reconcile_bank_statement_line(target_line uuid,target_payment uuid,target_reason text default null)
returns void language plpgsql security definer set search_path=public as $$
declare line bank_statement_lines%rowtype; p payments%rowtype; target_company uuid; expected_amount numeric(18,2); expected_direction payment_direction;
begin
  select l.* into line from bank_statement_lines l where l.id=target_line for update;
  if line.id is null then raise exception 'Statement line not found'; end if;
  select company_id into target_company from bank_accounts where id=line.bank_account_id;
  if target_company is null or not can_write_company(target_company) then raise exception 'Access denied'; end if;
  if line.reconciled then raise exception 'Statement line is already reconciled'; end if;
  perform pg_advisory_xact_lock(hashtextextended(target_payment::text,0));
  select * into p from payments where id=target_payment for update;
  if p.id is null or p.company_id<>target_company or p.bank_account_id<>line.bank_account_id or p.status<>'posted' then raise exception 'Posted payment for this bank account not found'; end if;
  expected_amount:=case when line.credit>0 then line.credit else line.debit end;
  expected_direction:=case when line.credit>0 then 'receipt'::payment_direction else 'payment'::payment_direction end;
  if p.direction<>expected_direction or p.amount<>expected_amount then raise exception 'Payment direction or amount does not match statement line'; end if;
  if exists(select 1 from bank_statement_lines where matched_payment_id=p.id and reconciled) then raise exception 'Payment is already reconciled'; end if;
  update bank_statement_lines set matched_payment_id=p.id,reconciled=true,reconciled_at=now(),reconciled_by=auth.uid() where id=line.id;
  insert into bank_reconciliation_log(company_id,bank_account_id,statement_line_id,payment_id,action,reason,performed_by)
  values(target_company,line.bank_account_id,line.id,p.id,'reconciled',nullif(trim(target_reason),''),auth.uid());
end; $$;

create or replace function public.unreconcile_bank_statement_line(target_line uuid,target_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare line bank_statement_lines%rowtype; target_company uuid; old_payment uuid;
begin
  select l.* into line from bank_statement_lines l where l.id=target_line for update;
  if line.id is null then raise exception 'Statement line not found'; end if;
  select company_id into target_company from bank_accounts where id=line.bank_account_id;
  if target_company is null or not can_write_company(target_company) then raise exception 'Access denied'; end if;
  if not line.reconciled then raise exception 'Statement line is not reconciled'; end if;
  if nullif(trim(target_reason),'') is null then raise exception 'Reason is required to unreconcile'; end if;
  old_payment:=line.matched_payment_id;
  update bank_statement_lines set matched_payment_id=null,reconciled=false,reconciled_at=null,reconciled_by=null where id=line.id;
  insert into bank_reconciliation_log(company_id,bank_account_id,statement_line_id,payment_id,action,reason,performed_by)
  values(target_company,line.bank_account_id,line.id,old_payment,'unreconciled',trim(target_reason),auth.uid());
end; $$;

revoke all on function public.import_bank_statement(uuid,text,jsonb) from public,anon;
revoke all on function public.reconcile_bank_statement_line(uuid,uuid,text) from public,anon;
revoke all on function public.unreconcile_bank_statement_line(uuid,text) from public,anon;
grant execute on function public.import_bank_statement(uuid,text,jsonb) to authenticated;
grant execute on function public.reconcile_bank_statement_line(uuid,uuid,text) to authenticated;
grant execute on function public.unreconcile_bank_statement_line(uuid,text) to authenticated;

commit;
