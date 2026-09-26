-- First least-privilege module role: Sales staff.
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
        or (m.role='viewer' and required_permission='reports')
        or (m.role='custom' and coalesce((m.permissions->>required_permission)::boolean,false))
      )
  );
$$;

create or replace function public.get_my_company_role(target_company uuid)
returns public.member_role language sql stable security definer set search_path=public as $$
  select role from company_members where company_id=target_company and user_id=auth.uid() and active;
$$;

alter table public.company_invitations drop constraint if exists company_invitations_role_check;
alter table public.company_invitations add constraint company_invitations_role_check
  check(role in ('admin','accountant','sales','viewer'));

create or replace function public.invite_company_member(target_company uuid,target_email text,target_role public.member_role)
returns text language plpgsql security definer set search_path=public as $$
declare normalized_email text:=lower(trim(target_email)); existing_user uuid; invitation_id uuid;
begin
  if not is_company_owner(target_company) then raise exception 'Owner access required'; end if;
  if normalized_email='' or position('@' in normalized_email)<=1 then raise exception 'Valid email is required'; end if;
  if target_role not in ('admin','accountant','sales','viewer') then raise exception 'Unsupported invitation role'; end if;
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
  if target_role not in ('owner','admin','accountant','sales','viewer') then raise exception 'Unsupported access role'; end if;
  if old_member.role='owner' and (target_role<>'owner' or not target_active) then
    select count(*) into owner_count from company_members where company_id=target_company and role='owner' and active and user_id<>target_user;
    if owner_count=0 then raise exception 'A company must retain at least one active owner'; end if;
  end if;
  update company_members set role=target_role,active=target_active where company_id=target_company and user_id=target_user;
  insert into audit_log(company_id,user_id,action,entity_type,entity_id,old_values,new_values)
  values(target_company,auth.uid(),'member_access_updated','company_member',target_user::text,
    jsonb_build_object('role',old_member.role,'active',old_member.active),jsonb_build_object('role',target_role,'active',target_active));
end; $$;

-- Direct Sales writes use Sales permission; reads remain available to company members.
drop policy if exists "writers manage contacts" on public.contacts;
drop policy if exists "sales staff manage contacts" on public.contacts;
create policy "sales staff manage contacts" on public.contacts for all
  using(public.has_company_permission(company_id,'sales')) with check(public.has_company_permission(company_id,'sales'));
drop policy if exists "writers manage sales invoices" on public.sales_invoices;
drop policy if exists "sales staff manage invoices" on public.sales_invoices;
create policy "sales staff manage invoices" on public.sales_invoices for all
  using(public.has_company_permission(company_id,'sales')) with check(public.has_company_permission(company_id,'sales'));
drop policy if exists "writers manage sales lines" on public.sales_invoice_lines;
drop policy if exists "sales staff manage invoice lines" on public.sales_invoice_lines;
create policy "sales staff manage invoice lines" on public.sales_invoice_lines for all
  using(exists(select 1 from sales_invoices i where i.id=invoice_id and public.has_company_permission(i.company_id,'sales')))
  with check(exists(select 1 from sales_invoices i where i.id=invoice_id and public.has_company_permission(i.company_id,'sales')));

create or replace function public.post_journal(target_entry uuid)
returns void language plpgsql security definer set search_path=public as $$
declare target_company uuid; total_debit numeric(18,2); total_credit numeric(18,2); line_count integer;
  required_permission text:=coalesce(nullif(current_setting('cloudledger.posting_permission',true),''),'accounting');
begin
  select company_id into target_company from journal_entries where id=target_entry and status='draft' for update;
  if target_company is null or not has_company_permission(target_company,required_permission) then raise exception 'Entry not found or posting access denied'; end if;
  select count(*),coalesce(sum(debit),0),coalesce(sum(credit),0) into line_count,total_debit,total_credit from journal_lines where entry_id=target_entry;
  if line_count<2 then raise exception 'At least two lines are required'; end if;
  if total_debit<=0 or total_debit<>total_credit then raise exception 'Journal entry is not balanced'; end if;
  update journal_entries set status='posted',posted_by=auth.uid(),posted_at=now() where id=target_entry;
end; $$;

create or replace function public.post_sales_invoice(target_invoice uuid)
returns void language plpgsql security definer set search_path=public as $$
declare inv sales_invoices%rowtype; sub numeric(18,2); tax numeric(18,2); grand numeric(18,2);
  ar_account uuid; sales_account uuid; gst_account uuid; inventory_account uuid; cogs_account uuid; new_journal uuid; target_warehouse uuid; line record; cogs_total numeric(18,2);
begin
  select * into inv from sales_invoices where id=target_invoice and status='draft' for update;
  if inv.id is null or not has_company_permission(inv.company_id,'sales') then raise exception 'Invoice not found or sales access denied'; end if;
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
  perform set_config('cloudledger.posting_permission','sales',true);
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

create or replace function public.create_journal_reversal(target_entry uuid,target_reason text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare source journal_entries%rowtype; reversal_id uuid;
  required_permission text:=coalesce(nullif(current_setting('cloudledger.posting_permission',true),''),'accounting');
begin
  select * into source from journal_entries where id=target_entry and status='posted' for update;
  if source.id is null or not has_company_permission(source.company_id,required_permission) then raise exception 'Posted journal not found or access denied'; end if;
  insert into journal_entries(company_id,branch_id,entry_date,reference,description,reversal_of,created_by)
  values(source.company_id,source.branch_id,current_date,'REV-'||source.entry_number,
    coalesce(nullif(trim(target_reason),''),'Reversal: '||coalesce(source.description,source.reference,'journal entry')),source.id,auth.uid()) returning id into reversal_id;
  insert into journal_lines(entry_id,account_id,description,debit,credit)
  select reversal_id,account_id,'Reversal: '||coalesce(description,''),credit,debit from journal_lines where entry_id=source.id;
  perform post_journal(reversal_id);
  perform set_config('cloudledger.allow_reversal','on',true);
  update journal_entries set status='reversed' where id=source.id;
  return reversal_id;
end; $$;

create or replace function public.void_sales_invoice(target_invoice uuid,target_reason text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare inv sales_invoices%rowtype; target_warehouse uuid; reversal_id uuid; line record;
begin
  select * into inv from sales_invoices where id=target_invoice and status='posted' for update;
  if inv.id is null or not has_company_permission(inv.company_id,'sales') then raise exception 'Posted invoice not found or sales access denied'; end if;
  if inv.amount_paid>0 then raise exception 'Paid invoice cannot be voided; reverse its receipt first'; end if;
  select id into target_warehouse from warehouses where company_id=inv.company_id and branch_id=inv.branch_id and active order by created_at limit 1;
  for line in select l.product_id,l.quantity,p.purchase_price from sales_invoice_lines l join products p on p.id=l.product_id where l.invoice_id=inv.id and not p.is_service loop
    insert into stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,reference,created_by)
    values(inv.company_id,target_warehouse,line.product_id,'return_in',current_date,line.quantity,line.purchase_price,'sales_invoice_void',inv.id,target_reason,auth.uid());
  end loop;
  perform set_config('cloudledger.posting_permission','sales',true);
  reversal_id:=create_journal_reversal(inv.journal_entry_id,target_reason);
  perform set_config('cloudledger.allow_document_void','on',true);
  update sales_invoices set status='void' where id=inv.id;
  return reversal_id;
end; $$;

revoke all on function public.has_company_permission(uuid,text) from public,anon;
revoke all on function public.get_my_company_role(uuid) from public,anon;
grant execute on function public.has_company_permission(uuid,text) to authenticated;
grant execute on function public.get_my_company_role(uuid) to authenticated;

commit;
