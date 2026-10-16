-- Serialize payroll finalization per company before checking actual employee snapshots.
-- READ COMMITTED is required so the query after a waiting lock sees the winner.
-- No historical posted runs or payroll amounts are changed by this migration.
create or replace function public.guard_payroll_period_overlap()
returns trigger language plpgsql volatile security definer set search_path=public as $$
begin
  if new.status not in ('posted','paid') then return new; end if;
  if tg_op='UPDATE' then
    if old.status in ('posted','paid') then return new; end if;
  end if;
  if current_setting('transaction_isolation') <> 'read committed' then
    raise exception 'Payroll posting requires READ COMMITTED isolation; retry in a new transaction';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('payroll-period:' || new.company_id::text,0));
  if new.period_start is null or new.period_end is null or new.period_end < new.period_start then
    raise exception 'Invalid payroll period';
  end if;
  if not exists(select 1 from public.payroll_items where payroll_run_id=new.id) then
    raise exception 'Prepare payroll items before posting';
  end if;
  if exists(select 1 from public.payroll_items i join public.employees e on e.id=i.employee_id
    where i.payroll_run_id=new.id and e.company_id<>new.company_id) then
    raise exception 'Payroll employee belongs to another company';
  end if;
  if exists(
    select 1 from public.payroll_items candidate
    join public.payroll_items prior on prior.employee_id=candidate.employee_id
    join public.payroll_runs r on r.id=prior.payroll_run_id
    where candidate.payroll_run_id=new.id and r.id<>new.id
      and r.company_id=new.company_id and r.status in ('posted','paid')
      and r.period_start<=new.period_end and r.period_end>=new.period_start
  ) then
    raise exception 'Payroll period overlaps an active posted payroll for an employee. Review or reverse the original payroll in History before posting a replacement.';
  end if;
  return new;
end $$;
revoke all on function public.guard_payroll_period_overlap() from public;
create trigger payroll_period_overlap_guard before insert or update of status on public.payroll_runs
for each row execute function public.guard_payroll_period_overlap();
create index if not exists payroll_items_employee_run_idx on public.payroll_items(employee_id,payroll_run_id);
create index if not exists payroll_runs_active_period_idx on public.payroll_runs(company_id,period_start,period_end)
where status in ('posted','paid');
