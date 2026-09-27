-- Least-privilege Purchase staff role with audit-safe bill posting and reversal.
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
        or (m.role='viewer' and required_permission='reports')
        or (m.role='custom' and coalesce((m.permissions->>required_permission)::boolean,false))
      )
  );
$$;

alter table public.company_invitations drop constraint if exists company_invitations_role_check;
alter table public.company_invitations add constraint company_invitations_role_check
  check(role in ('admin','accountant','sales','purchases','viewer'));

create or replace function public.invite_company_member(target_company uuid,target_email text,target_role public.member_role)
returns text language plpgsql security definer set search_path=public as $$
declare normalized_email text:=lower(trim(target_email)); existing_user uuid; invitation_id uuid;
begin
  if not is_company_owner(target_company) then raise exception 'Owner access required'; end if;
  if normalized_email='' or position('@' in normalized_email)<=1 then raise exception 'Valid email is required'; end if;
  if target_role not in ('admin','accountant','sales','purchases','viewer') then raise exception 'Unsupported invitation role'; end if;
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
  if target_role not in ('owner','admin','accountant','sales','purchases','viewer') then raise exception 'Unsupported access role'; end if;
  if old_member.role='owner' and (target_role<>'owner' or not target_active) then
    select count(*) into owner_count from company_members where company_id=target_company and role='owner' and active and user_id<>target_user;
    if owner_count=0 then raise exception 'A company must retain at least one active owner'; end if;
  end if;
  update company_members set role=target_role,active=target_active where company_id=target_company and user_id=target_user;
  insert into audit_log(company_id,user_id,action,entity_type,entity_id,old_values,new_values)
  values(target_company,auth.uid(),'member_access_updated','company_member',target_user::text,
    jsonb_build_object('role',old_member.role,'active',old_member.active),jsonb_build_object('role',target_role,'active',target_active));
end; $$;

-- Suppliers are shared contact records, so preserve Sales access and add Purchases access.
drop policy if exists "sales staff manage contacts" on public.contacts;
drop policy if exists "sales and purchase staff manage contacts" on public.contacts;
create policy "sales and purchase staff manage contacts" on public.contacts for all
  using(public.has_company_permission(company_id,'sales') or public.has_company_permission(company_id,'purchases'))
  with check(public.has_company_permission(company_id,'sales') or public.has_company_permission(company_id,'purchases'));

drop policy if exists "writers_manage_purchase_bills" on public.purchase_bills;
drop policy if exists "purchase staff manage bills" on public.purchase_bills;
create policy "purchase staff manage bills" on public.purchase_bills for all
  using(public.has_company_permission(company_id,'purchases')) with check(public.has_company_permission(company_id,'purchases'));
drop policy if exists "writers manage purchase lines" on public.purchase_bill_lines;
drop policy if exists "purchase staff manage bill lines" on public.purchase_bill_lines;
create policy "purchase staff manage bill lines" on public.purchase_bill_lines for all
  using(exists(select 1 from purchase_bills b where b.id=bill_id and public.has_company_permission(b.company_id,'purchases')))
  with check(exists(select 1 from purchase_bills b where b.id=bill_id and public.has_company_permission(b.company_id,'purchases')));

create or replace function public.post_purchase_bill(target_bill uuid)
returns void language plpgsql security definer set search_path=public as $$
declare bill purchase_bills%rowtype; sub numeric(18,2); tax numeric(18,2); grand numeric(18,2);
  ap_account uuid; inventory_account uuid; input_tax_account uuid; new_journal uuid; line record;
begin
  select * into bill from purchase_bills where id=target_bill and status='draft' for update;
  if bill.id is null or not has_company_permission(bill.company_id,'purchases') then raise exception 'Bill not found or purchase access denied'; end if;
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
  perform set_config('cloudledger.posting_permission','purchases',true);
  perform post_journal(new_journal);
  update purchase_bills set subtotal=sub,gst_total=tax,total=grand,status='posted',journal_entry_id=new_journal,posted_at=now() where id=bill.id;
  if bill.warehouse_id is not null then
    for line in select l.product_id,l.quantity,l.unit_price from purchase_bill_lines l join products p on p.id=l.product_id where l.bill_id=bill.id and not p.is_service loop
      insert into stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,created_by)
      values(bill.company_id,bill.warehouse_id,line.product_id,'purchase',bill.bill_date,line.quantity,line.unit_price,'purchase_bill',bill.id,auth.uid());
    end loop;
  end if;
end; $$;

create or replace function public.void_purchase_bill(target_bill uuid,target_reason text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare bill purchase_bills%rowtype; reversal_id uuid; line record;
begin
  select * into bill from purchase_bills where id=target_bill and status='posted' for update;
  if bill.id is null or not has_company_permission(bill.company_id,'purchases') then raise exception 'Posted bill not found or purchase access denied'; end if;
  if bill.amount_paid>0 then raise exception 'Paid bill cannot be voided; reverse its payment first'; end if;
  for line in select l.product_id,l.quantity,l.unit_price from purchase_bill_lines l join products p on p.id=l.product_id where l.bill_id=bill.id and not p.is_service loop
    insert into stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,reference,created_by)
    values(bill.company_id,bill.warehouse_id,line.product_id,'return_out',current_date,line.quantity,line.unit_price,'purchase_bill_void',bill.id,target_reason,auth.uid());
  end loop;
  perform set_config('cloudledger.posting_permission','purchases',true);
  reversal_id:=create_journal_reversal(bill.journal_entry_id,target_reason);
  perform set_config('cloudledger.allow_document_void','on',true);
  update purchase_bills set status='void' where id=bill.id;
  return reversal_id;
end; $$;

revoke all on function public.has_company_permission(uuid,text) from public,anon;
grant execute on function public.has_company_permission(uuid,text) to authenticated;

commit;
