-- Least-privilege Payroll staff access, auditable attendance/leave and safe payroll reversals.
begin;

create or replace function public.has_company_permission(target_company uuid,required_permission text)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(
    select 1 from company_members m
    where m.company_id=target_company and m.user_id=auth.uid() and m.active
      and (
        m.role in ('owner','admin')
        or (m.role='accountant' and required_permission in ('accounting','sales','purchases','inventory','payroll','banking','reports'))
        or (m.role='sales' and required_permission in ('sales','reports'))
        or (m.role='purchases' and required_permission in ('purchases','reports'))
        or (m.role='inventory' and required_permission in ('inventory','reports'))
        or (m.role='payroll' and required_permission in ('payroll','reports'))
        or (m.role='viewer' and required_permission='reports')
        or (m.role='custom' and coalesce((m.permissions->>required_permission)::boolean,false))
      )
  );
$$;

alter table public.company_invitations drop constraint if exists company_invitations_role_check;
alter table public.company_invitations add constraint company_invitations_role_check
  check(role in ('admin','accountant','sales','purchases','inventory','payroll','viewer'));

create or replace function public.invite_company_member(target_company uuid,target_email text,target_role public.member_role)
returns text language plpgsql security definer set search_path=public as $$
declare normalized_email text:=lower(trim(target_email)); existing_user uuid; invitation_id uuid;
begin
  if not is_company_owner(target_company) then raise exception 'Owner access required'; end if;
  if normalized_email='' or position('@' in normalized_email)<=1 then raise exception 'Valid email is required'; end if;
  if target_role not in ('admin','accountant','sales','purchases','inventory','payroll','viewer') then raise exception 'Unsupported invitation role'; end if;
  select u.id into existing_user from auth.users u where lower(u.email)=normalized_email limit 1;
  if existing_user is not null then
    insert into company_members(company_id,user_id,role,active) values(target_company,existing_user,target_role,true)
    on conflict(company_id,user_id) do update set role=case when company_members.role='owner' then company_members.role else excluded.role end,active=true;
    insert into audit_log(company_id,user_id,action,entity_type,entity_id,new_values)
    values(target_company,auth.uid(),'member_added_or_reactivated','company_member',existing_user::text,jsonb_build_object('email',normalized_email,'role',target_role));
    return 'Member added';
  end if;
  update company_invitations set role=target_role,expires_at=now()+interval '14 days',invited_by=auth.uid()
    where company_id=target_company and email=normalized_email and accepted_at is null and revoked_at is null returning id into invitation_id;
  if invitation_id is null then insert into company_invitations(company_id,email,role,invited_by) values(target_company,normalized_email,target_role,auth.uid()) returning id into invitation_id; end if;
  insert into audit_log(company_id,user_id,action,entity_type,entity_id,new_values)
  values(target_company,auth.uid(),'member_invited','company_invitation',invitation_id::text,jsonb_build_object('email',normalized_email,'role',target_role));
  return 'Invitation pending';
end; $$;

create or replace function public.update_company_member(target_company uuid,target_user uuid,target_role public.member_role,target_active boolean)
returns void language plpgsql security definer set search_path=public as $$
declare old_member company_members%rowtype; owner_count integer;
begin
  if not is_company_owner(target_company) then raise exception 'Owner access required'; end if;
  select * into old_member from company_members where company_id=target_company and user_id=target_user for update;
  if old_member.user_id is null then raise exception 'Company member not found'; end if;
  if target_role not in ('owner','admin','accountant','sales','purchases','inventory','payroll','viewer') then raise exception 'Unsupported access role'; end if;
  if old_member.role='owner' and (target_role<>'owner' or not target_active) then
    select count(*) into owner_count from company_members where company_id=target_company and role='owner' and active and user_id<>target_user;
    if owner_count=0 then raise exception 'A company must retain at least one active owner'; end if;
  end if;
  update company_members set role=target_role,active=target_active where company_id=target_company and user_id=target_user;
  insert into audit_log(company_id,user_id,action,entity_type,entity_id,old_values,new_values)
  values(target_company,auth.uid(),'member_access_updated','company_member',target_user::text,
    jsonb_build_object('role',old_member.role,'active',old_member.active),jsonb_build_object('role',target_role,'active',target_active));
end; $$;

drop policy if exists writers_manage_employees on public.employees;
create policy payroll_staff_manage_employees on public.employees for all using(has_company_permission(company_id,'payroll')) with check(has_company_permission(company_id,'payroll'));
drop policy if exists writers_manage_attendance on public.attendance;
create policy payroll_staff_manage_attendance on public.attendance for all using(has_company_permission(company_id,'payroll')) with check(has_company_permission(company_id,'payroll'));
drop policy if exists writers_manage_leave_requests on public.leave_requests;
create policy payroll_staff_manage_leave_requests on public.leave_requests for all using(has_company_permission(company_id,'payroll')) with check(has_company_permission(company_id,'payroll'));
drop policy if exists writers_manage_employee_loans on public.employee_loans;
create policy payroll_staff_manage_employee_loans on public.employee_loans for all using(has_company_permission(company_id,'payroll')) with check(has_company_permission(company_id,'payroll'));
drop policy if exists writers_manage_payroll_runs on public.payroll_runs;
create policy payroll_staff_manage_payroll_runs on public.payroll_runs for all using(has_company_permission(company_id,'payroll')) with check(has_company_permission(company_id,'payroll'));
drop policy if exists "writers manage salary components" on public.employee_salary_components;
create policy "payroll staff manage salary components" on public.employee_salary_components for all
  using(exists(select 1 from employees e where e.id=employee_id and has_company_permission(e.company_id,'payroll')))
  with check(exists(select 1 from employees e where e.id=employee_id and has_company_permission(e.company_id,'payroll')));
drop policy if exists "writers manage payroll items" on public.payroll_items;
create policy "payroll staff manage payroll items" on public.payroll_items for all
  using(exists(select 1 from payroll_runs r where r.id=payroll_run_id and has_company_permission(r.company_id,'payroll')))
  with check(exists(select 1 from payroll_runs r where r.id=payroll_run_id and has_company_permission(r.company_id,'payroll')));

create or replace function public.record_employee_attendance(target_company uuid,target_employee uuid,target_date date,target_status text,target_check_in time default null,target_check_out time default null,target_overtime numeric default 0,target_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare attendance_id uuid; previous jsonb;
begin
  if not has_company_permission(target_company,'payroll') then raise exception 'Payroll access denied'; end if;
  if not exists(select 1 from employees where id=target_employee and company_id=target_company and active) then raise exception 'Active employee not found'; end if;
  if target_status not in ('present','absent','leave','holiday') then raise exception 'Invalid attendance status'; end if;
  if coalesce(target_overtime,0)<0 then raise exception 'Overtime cannot be negative'; end if;
  if target_check_in is not null and target_check_out is not null and target_check_out<=target_check_in then raise exception 'Check-out must be after check-in'; end if;
  select to_jsonb(a) into previous from attendance a where employee_id=target_employee and attendance_date=target_date;
  insert into attendance(company_id,employee_id,attendance_date,status,check_in,check_out,overtime_hours,notes)
  values(target_company,target_employee,target_date,target_status,target_check_in,target_check_out,coalesce(target_overtime,0),nullif(trim(target_notes),''))
  on conflict(employee_id,attendance_date) do update set status=excluded.status,check_in=excluded.check_in,check_out=excluded.check_out,overtime_hours=excluded.overtime_hours,notes=excluded.notes
  returning id into attendance_id;
  insert into audit_log(company_id,user_id,action,entity_type,entity_id,old_values,new_values)
  values(target_company,auth.uid(),case when previous is null then 'attendance_recorded' else 'attendance_updated' end,'attendance',attendance_id::text,previous,
    jsonb_build_object('employee_id',target_employee,'date',target_date,'status',target_status,'overtime_hours',coalesce(target_overtime,0)));
  return attendance_id;
end; $$;

create or replace function public.submit_employee_leave(target_company uuid,target_employee uuid,target_type text,target_start date,target_end date,target_paid boolean,target_reason text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare leave_id uuid;
begin
  if not has_company_permission(target_company,'payroll') then raise exception 'Payroll access denied'; end if;
  if not exists(select 1 from employees where id=target_employee and company_id=target_company and active) then raise exception 'Active employee not found'; end if;
  if nullif(trim(target_type),'') is null then raise exception 'Leave type is required'; end if;
  if target_end<target_start then raise exception 'Leave end date cannot precede start date'; end if;
  if exists(select 1 from leave_requests where employee_id=target_employee and status in ('pending','approved') and daterange(start_date,end_date,'[]') && daterange(target_start,target_end,'[]')) then raise exception 'Leave dates overlap an existing request'; end if;
  insert into leave_requests(company_id,employee_id,leave_type,start_date,end_date,paid,reason)
  values(target_company,target_employee,trim(target_type),target_start,target_end,target_paid,nullif(trim(target_reason),'')) returning id into leave_id;
  insert into audit_log(company_id,user_id,action,entity_type,entity_id,new_values)
  values(target_company,auth.uid(),'leave_submitted','leave_request',leave_id::text,jsonb_build_object('employee_id',target_employee,'start_date',target_start,'end_date',target_end,'paid',target_paid));
  return leave_id;
end; $$;

create or replace function public.review_employee_leave(target_leave uuid,target_status public.leave_request_status)
returns void language plpgsql security definer set search_path=public as $$
declare request leave_requests%rowtype;
begin
  select * into request from leave_requests where id=target_leave and status='pending' for update;
  if request.id is null or not has_company_permission(request.company_id,'payroll') then raise exception 'Pending leave request not found or access denied'; end if;
  if target_status not in ('approved','rejected') then raise exception 'Leave can only be approved or rejected'; end if;
  update leave_requests set status=target_status,approved_by=auth.uid() where id=request.id;
  insert into audit_log(company_id,user_id,action,entity_type,entity_id,old_values,new_values)
  values(request.company_id,auth.uid(),'leave_reviewed','leave_request',request.id::text,jsonb_build_object('status',request.status),jsonb_build_object('status',target_status));
end; $$;

create or replace function public.prepare_payroll_run(target_run uuid)
returns void language plpgsql security definer set search_path=public as $$
declare r payroll_runs%rowtype;
begin
  select * into r from payroll_runs where id=target_run and status='draft' for update;
  if r.id is null or not has_company_permission(r.company_id,'payroll') then raise exception 'Payroll run not found or payroll access denied'; end if;
  delete from payroll_items where payroll_run_id=r.id;
  insert into payroll_items(payroll_run_id,employee_id,base_salary,allowances,deductions,loan_deduction,income_tax,eobi,sessi)
  select r.id,e.id,e.base_salary,
    coalesce((select sum(case when component_type='allowance' then coalesce(amount,e.base_salary*percentage/100) else 0 end) from employee_salary_components c where c.employee_id=e.id and c.active),0),
    coalesce((select sum(case when component_type='deduction' then coalesce(amount,e.base_salary*percentage/100) else 0 end) from employee_salary_components c where c.employee_id=e.id and c.active),0)
      + round((e.base_salary/30)*coalesce((select sum(least(l.end_date,r.period_end)-greatest(l.start_date,r.period_start)+1) from leave_requests l where l.employee_id=e.id and l.status='approved' and not l.paid and l.start_date<=r.period_end and l.end_date>=r.period_start),0),2),
    coalesce((select least(installment_amount,principal-recovered_amount) from employee_loans l where l.employee_id=e.id and l.active order by loan_date limit 1),0),
    case when e.tax_enabled then e.monthly_income_tax else 0 end,case when e.eobi_enabled then e.monthly_eobi else 0 end,case when e.sessi_enabled then e.monthly_sessi else 0 end
  from employees e where e.company_id=r.company_id and e.active and (r.branch_id is null or e.branch_id=r.branch_id);
  if exists(select 1 from payroll_items where payroll_run_id=r.id and net_salary<0) then raise exception 'Payroll contains an employee with negative net salary'; end if;
  update payroll_runs pr set gross_total=x.gross,deduction_total=x.deductions,tax_total=x.tax,eobi_total=x.eobi,sessi_total=x.sessi,net_total=x.net
  from (select coalesce(sum(gross_salary),0) gross,coalesce(sum(deductions+loan_deduction),0) deductions,coalesce(sum(income_tax),0) tax,coalesce(sum(eobi),0) eobi,coalesce(sum(sessi),0) sessi,coalesce(sum(net_salary),0) net from payroll_items where payroll_run_id=r.id) x where pr.id=r.id;
end; $$;

create or replace function public.post_payroll_run(target_run uuid)
returns void language plpgsql security definer set search_path=public as $$
declare r payroll_runs%rowtype; salary_expense uuid; payroll_payable uuid; tax_payable uuid; eobi_payable uuid; sessi_payable uuid; new_journal uuid;
begin
  select * into r from payroll_runs where id=target_run and status='draft' for update;
  if r.id is null or not has_company_permission(r.company_id,'payroll') then raise exception 'Payroll run not found or payroll access denied'; end if;
  perform prepare_payroll_run(target_run); select * into r from payroll_runs where id=target_run;
  if r.gross_total<=0 then raise exception 'Payroll run has no payable employees'; end if;
  select id into salary_expense from accounts where company_id=r.company_id and code='6200'; select id into payroll_payable from accounts where company_id=r.company_id and code='2200'; select id into tax_payable from accounts where company_id=r.company_id and code='2050'; select id into eobi_payable from accounts where company_id=r.company_id and code='2210'; select id into sessi_payable from accounts where company_id=r.company_id and code='2220';
  if salary_expense is null or payroll_payable is null or tax_payable is null or eobi_payable is null or sessi_payable is null then raise exception 'Payroll control accounts are incomplete'; end if;
  insert into journal_entries(company_id,branch_id,entry_date,reference,description,created_by) values(r.company_id,r.branch_id,r.period_end,'PAYROLL-'||to_char(r.period_end,'YYYYMM'),'Monthly payroll',auth.uid()) returning id into new_journal;
  insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,salary_expense,'Gross payroll',r.gross_total,0),(new_journal,payroll_payable,'Net salaries payable',0,r.net_total);
  if r.deduction_total>0 then insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,payroll_payable,'Other deductions',0,r.deduction_total); end if;
  if r.tax_total>0 then insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,tax_payable,'Salary tax',0,r.tax_total); end if;
  if r.eobi_total>0 then insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,eobi_payable,'EOBI',0,r.eobi_total); end if;
  if r.sessi_total>0 then insert into journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,sessi_payable,'SESSI',0,r.sessi_total); end if;
  perform set_config('cloudledger.posting_permission','payroll',true); perform post_journal(new_journal);
  update payroll_runs set status='posted',journal_entry_id=new_journal,posted_at=now() where id=r.id;
end; $$;

create or replace function public.protect_payroll_run()
returns trigger language plpgsql set search_path=public as $$
begin
  if tg_op='DELETE' and old.status not in ('draft','approved') then raise exception 'Posted payroll is immutable'; end if;
  if tg_op='UPDATE' and old.status not in ('draft','approved') then
    if old.status='posted' and new.status='void' and current_setting('cloudledger.allow_payroll_void',true)='on' and (to_jsonb(new)-'status')=(to_jsonb(old)-'status') then return new; end if;
    raise exception 'Posted payroll is immutable';
  end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;
drop trigger if exists payroll_run_immutable on public.payroll_runs;
create trigger payroll_run_immutable before update or delete on public.payroll_runs for each row execute function public.protect_payroll_run();

create or replace function public.protect_payroll_items()
returns trigger language plpgsql set search_path=public as $$
declare parent_status public.payroll_run_status;
begin
  select status into parent_status from payroll_runs where id=coalesce(new.payroll_run_id,old.payroll_run_id);
  if parent_status not in ('draft','approved') then raise exception 'Posted payroll items are immutable'; end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;
drop trigger if exists payroll_items_immutable on public.payroll_items;
create trigger payroll_items_immutable before insert or update or delete on public.payroll_items for each row execute function public.protect_payroll_items();

create or replace function public.void_payroll_run(target_run uuid,target_reason text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare r payroll_runs%rowtype; reversal_id uuid;
begin
  select * into r from payroll_runs where id=target_run and status='posted' for update;
  if r.id is null or not has_company_permission(r.company_id,'payroll') then raise exception 'Posted payroll not found or payroll access denied'; end if;
  perform set_config('cloudledger.posting_permission','payroll',true);
  reversal_id:=create_journal_reversal(r.journal_entry_id,target_reason);
  perform set_config('cloudledger.allow_payroll_void','on',true);
  update payroll_runs set status='void' where id=r.id;
  return reversal_id;
end; $$;

revoke all on function public.record_employee_attendance(uuid,uuid,date,text,time,time,numeric,text) from public,anon;
revoke all on function public.submit_employee_leave(uuid,uuid,text,date,date,boolean,text) from public,anon;
revoke all on function public.review_employee_leave(uuid,public.leave_request_status) from public,anon;
revoke all on function public.void_payroll_run(uuid,text) from public,anon;
grant execute on function public.record_employee_attendance(uuid,uuid,date,text,time,time,numeric,text) to authenticated;
grant execute on function public.submit_employee_leave(uuid,uuid,text,date,date,boolean,text) to authenticated;
grant execute on function public.review_employee_leave(uuid,public.leave_request_status) to authenticated;
grant execute on function public.void_payroll_run(uuid,text) to authenticated;

commit;
