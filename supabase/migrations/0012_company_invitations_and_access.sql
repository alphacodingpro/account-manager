-- Owner-controlled company invitations and auditable member role management.
begin;

create table public.company_invitations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  email text not null check(email=lower(trim(email)) and position('@' in email)>1),
  role public.member_role not null check(role in ('admin','accountant','viewer')),
  invited_by uuid not null references auth.users(id),
  expires_at timestamptz not null default (now()+interval '14 days'),
  accepted_at timestamptz,
  accepted_by uuid references auth.users(id),
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

create unique index company_invitations_one_pending_email
  on public.company_invitations(company_id,email)
  where accepted_at is null and revoked_at is null;

alter table public.company_invitations enable row level security;

create or replace function public.is_company_owner(target_company uuid)
returns boolean language sql stable security definer set search_path=public
as $$
  select exists(select 1 from company_members where company_id=target_company and user_id=auth.uid() and role='owner' and active);
$$;

create policy "owners read company invitations" on public.company_invitations for select
using(public.is_company_owner(company_id));

create or replace function public.get_company_members(target_company uuid)
returns table(user_id uuid,full_name text,email text,role public.member_role,active boolean,joined_at timestamptz)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_company_owner(target_company) then raise exception 'Owner access required'; end if;
  return query
    select m.user_id,coalesce(p.full_name,''),coalesce(u.email,''),m.role,m.active,m.created_at
    from company_members m
    join auth.users u on u.id=m.user_id
    left join profiles p on p.id=m.user_id
    where m.company_id=target_company
    order by case m.role when 'owner' then 0 when 'admin' then 1 when 'accountant' then 2 else 3 end,coalesce(p.full_name,u.email);
end; $$;

create or replace function public.get_company_invitations(target_company uuid)
returns table(id uuid,email text,role public.member_role,expires_at timestamptz,created_at timestamptz)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_company_owner(target_company) then raise exception 'Owner access required'; end if;
  return query select i.id,i.email,i.role,i.expires_at,i.created_at
    from company_invitations i
    where i.company_id=target_company and i.accepted_at is null and i.revoked_at is null and i.expires_at>now()
    order by i.created_at desc;
end; $$;

create or replace function public.invite_company_member(target_company uuid,target_email text,target_role public.member_role)
returns text language plpgsql security definer set search_path=public as $$
declare normalized_email text:=lower(trim(target_email)); existing_user uuid; invitation_id uuid;
begin
  if not is_company_owner(target_company) then raise exception 'Owner access required'; end if;
  if normalized_email='' or position('@' in normalized_email)<=1 then raise exception 'Valid email is required'; end if;
  if target_role not in ('admin','accountant','viewer') then raise exception 'Invitations may use manager, accountant or viewer access'; end if;

  select u.id into existing_user from auth.users u where lower(u.email)=normalized_email limit 1;
  if existing_user is not null then
    insert into company_members(company_id,user_id,role,active)
    values(target_company,existing_user,target_role,true)
    on conflict(company_id,user_id) do update set
      role=case when company_members.role='owner' then company_members.role else excluded.role end,
      active=true;
    insert into audit_log(company_id,user_id,action,entity_type,entity_id,new_values)
    values(target_company,auth.uid(),'member_added_or_reactivated','company_member',existing_user::text,jsonb_build_object('email',normalized_email,'role',target_role));
    return 'Member added';
  end if;

  update company_invitations set role=target_role,expires_at=now()+interval '14 days',invited_by=auth.uid()
    where company_id=target_company and email=normalized_email and accepted_at is null and revoked_at is null
    returning id into invitation_id;
  if invitation_id is null then
    insert into company_invitations(company_id,email,role,invited_by)
    values(target_company,normalized_email,target_role,auth.uid()) returning id into invitation_id;
  end if;
  insert into audit_log(company_id,user_id,action,entity_type,entity_id,new_values)
  values(target_company,auth.uid(),'member_invited','company_invitation',invitation_id::text,jsonb_build_object('email',normalized_email,'role',target_role));
  return 'Invitation pending';
end; $$;

create or replace function public.accept_my_company_invitations()
returns integer language plpgsql security definer set search_path=public as $$
declare accepted_count integer:=0; current_email text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select lower(u.email) into current_email from auth.users u where u.id=auth.uid();
  if current_email is null then return 0; end if;

  with accepted as (
    update company_invitations i set accepted_at=now(),accepted_by=auth.uid()
    where i.email=current_email and i.accepted_at is null and i.revoked_at is null and i.expires_at>now()
    returning i.company_id,i.role,i.id
  ), inserted as (
    insert into company_members(company_id,user_id,role,active)
    select a.company_id,auth.uid(),a.role,true from accepted a
    on conflict(company_id,user_id) do update set
      role=case when company_members.role='owner' then company_members.role else excluded.role end,
      active=true
    returning company_id
  ) select count(*) into accepted_count from inserted;
  return accepted_count;
end; $$;

create or replace function public.update_company_member(target_company uuid,target_user uuid,target_role public.member_role,target_active boolean)
returns void language plpgsql security definer set search_path=public as $$
declare old_member company_members%rowtype; owner_count integer;
begin
  if not is_company_owner(target_company) then raise exception 'Owner access required'; end if;
  select * into old_member from company_members where company_id=target_company and user_id=target_user for update;
  if old_member.user_id is null then raise exception 'Company member not found'; end if;
  if target_role not in ('owner','admin','accountant','viewer') then raise exception 'Unsupported access role'; end if;
  if old_member.role='owner' and (target_role<>'owner' or not target_active) then
    select count(*) into owner_count from company_members where company_id=target_company and role='owner' and active and user_id<>target_user;
    if owner_count=0 then raise exception 'A company must retain at least one active owner'; end if;
  end if;
  update company_members set role=target_role,active=target_active where company_id=target_company and user_id=target_user;
  insert into audit_log(company_id,user_id,action,entity_type,entity_id,old_values,new_values)
  values(target_company,auth.uid(),'member_access_updated','company_member',target_user::text,
    jsonb_build_object('role',old_member.role,'active',old_member.active),jsonb_build_object('role',target_role,'active',target_active));
end; $$;

create or replace function public.revoke_company_invitation(target_invitation uuid)
returns void language plpgsql security definer set search_path=public as $$
declare target_company uuid;
begin
  select company_id into target_company from company_invitations where id=target_invitation and accepted_at is null and revoked_at is null for update;
  if target_company is null or not is_company_owner(target_company) then raise exception 'Invitation not found or owner access required'; end if;
  update company_invitations set revoked_at=now() where id=target_invitation;
  insert into audit_log(company_id,user_id,action,entity_type,entity_id)
  values(target_company,auth.uid(),'member_invitation_revoked','company_invitation',target_invitation::text);
end; $$;

-- Branches were originally writable by every member. Keep reads broad, but restrict writes.
drop policy if exists "member branches" on public.branches;
drop policy if exists "members read branches" on public.branches;
drop policy if exists "writers insert branches" on public.branches;
drop policy if exists "writers update branches" on public.branches;
drop policy if exists "writers delete branches" on public.branches;
create policy "members read branches" on public.branches for select using(public.is_company_member(company_id));
create policy "writers insert branches" on public.branches for insert with check(public.can_write_company(company_id));
create policy "writers update branches" on public.branches for update using(public.can_write_company(company_id)) with check(public.can_write_company(company_id));
create policy "writers delete branches" on public.branches for delete using(public.can_write_company(company_id));

revoke all on function public.is_company_owner(uuid) from public,anon;
revoke all on function public.get_company_members(uuid) from public,anon;
revoke all on function public.get_company_invitations(uuid) from public,anon;
revoke all on function public.invite_company_member(uuid,text,public.member_role) from public,anon;
revoke all on function public.accept_my_company_invitations() from public,anon;
revoke all on function public.update_company_member(uuid,uuid,public.member_role,boolean) from public,anon;
revoke all on function public.revoke_company_invitation(uuid) from public,anon;
grant execute on function public.is_company_owner(uuid) to authenticated;
grant execute on function public.get_company_members(uuid) to authenticated;
grant execute on function public.get_company_invitations(uuid) to authenticated;
grant execute on function public.invite_company_member(uuid,text,public.member_role) to authenticated;
grant execute on function public.accept_my_company_invitations() to authenticated;
grant execute on function public.update_company_member(uuid,uuid,public.member_role,boolean) to authenticated;
grant execute on function public.revoke_company_invitation(uuid) to authenticated;

commit;
