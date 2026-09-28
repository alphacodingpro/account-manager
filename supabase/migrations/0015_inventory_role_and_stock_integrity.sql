-- Least-privilege Inventory staff role and append-only stock controls.
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
        or (m.role='viewer' and required_permission='reports')
        or (m.role='custom' and coalesce((m.permissions->>required_permission)::boolean,false))
      )
  );
$$;

alter table public.company_invitations drop constraint if exists company_invitations_role_check;
alter table public.company_invitations add constraint company_invitations_role_check
  check(role in ('admin','accountant','sales','purchases','inventory','viewer'));

create or replace function public.invite_company_member(target_company uuid,target_email text,target_role public.member_role)
returns text language plpgsql security definer set search_path=public as $$
declare normalized_email text:=lower(trim(target_email)); existing_user uuid; invitation_id uuid;
begin
  if not is_company_owner(target_company) then raise exception 'Owner access required'; end if;
  if normalized_email='' or position('@' in normalized_email)<=1 then raise exception 'Valid email is required'; end if;
  if target_role not in ('admin','accountant','sales','purchases','inventory','viewer') then raise exception 'Unsupported invitation role'; end if;
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
  if target_role not in ('owner','admin','accountant','sales','purchases','inventory','viewer') then raise exception 'Unsupported access role'; end if;
  if old_member.role='owner' and (target_role<>'owner' or not target_active) then
    select count(*) into owner_count from company_members where company_id=target_company and role='owner' and active and user_id<>target_user;
    if owner_count=0 then raise exception 'A company must retain at least one active owner'; end if;
  end if;
  update company_members set role=target_role,active=target_active where company_id=target_company and user_id=target_user;
  insert into audit_log(company_id,user_id,action,entity_type,entity_id,old_values,new_values)
  values(target_company,auth.uid(),'member_access_updated','company_member',target_user::text,
    jsonb_build_object('role',old_member.role,'active',old_member.active),jsonb_build_object('role',target_role,'active',target_active));
end; $$;

-- Product master data may be managed by Inventory staff, but stock quantity is protected below.
drop policy if exists "writers manage products" on public.products;
drop policy if exists "inventory staff manage products" on public.products;
create policy "inventory staff manage products" on public.products for all
  using(public.has_company_permission(company_id,'inventory')) with check(public.has_company_permission(company_id,'inventory'));

-- Stock movements are an append-only audit ledger. All mutations go through controlled functions.
drop policy if exists "writers_manage_stock_movements" on public.stock_movements;

create or replace function public.protect_stock_movement_history()
returns trigger language plpgsql set search_path=public as $$
begin
  raise exception 'Stock movement history is append-only';
end; $$;
drop trigger if exists stock_movement_history_immutable on public.stock_movements;
create trigger stock_movement_history_immutable before update or delete on public.stock_movements
for each row execute function public.protect_stock_movement_history();

create or replace function public.protect_product_stock_quantity()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.company_id is distinct from old.company_id then
    raise exception 'Product company cannot be changed';
  end if;
  if new.quantity_on_hand is distinct from old.quantity_on_hand
     and coalesce(current_setting('cloudledger.allow_stock_quantity',true),'')<>'on' then
    raise exception 'Stock quantity can only change through a stock movement';
  end if;
  return new;
end; $$;
drop trigger if exists product_stock_quantity_control on public.products;
create trigger product_stock_quantity_control before update on public.products
for each row execute function public.protect_product_stock_quantity();

create or replace function public.apply_stock_movement()
returns trigger language plpgsql security definer set search_path=public as $$
declare multiplier numeric;
begin
  if not exists(select 1 from warehouses w where w.id=new.warehouse_id and w.company_id=new.company_id and w.active) then raise exception 'Warehouse does not belong to company or is inactive'; end if;
  if not exists(select 1 from products p where p.id=new.product_id and p.company_id=new.company_id and p.active and not p.is_service) then raise exception 'Invalid stock product'; end if;
  multiplier:=case when new.movement_type in ('opening','purchase','adjustment_in','transfer_in','return_in') then 1 else -1 end;
  perform set_config('cloudledger.allow_stock_quantity','on',true);
  update products set quantity_on_hand=quantity_on_hand+(new.quantity*multiplier) where id=new.product_id;
  perform set_config('cloudledger.allow_stock_quantity','',true);
  if (select quantity_on_hand from products where id=new.product_id)<0 then raise exception 'Insufficient stock'; end if;
  return new;
end; $$;

create or replace function public.record_stock_adjustment(target_company uuid,target_warehouse uuid,target_product uuid,target_quantity numeric,target_increase boolean,target_reference text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare new_id uuid;
begin
  if not has_company_permission(target_company,'inventory') then raise exception 'Inventory access denied'; end if;
  if target_quantity<=0 then raise exception 'Quantity must be greater than zero'; end if;
  if nullif(trim(target_reference),'') is null then raise exception 'Adjustment reference is required'; end if;
  insert into stock_movements(company_id,warehouse_id,product_id,movement_type,quantity,reference,created_by)
  values(target_company,target_warehouse,target_product,case when target_increase then 'adjustment_in'::stock_movement_type else 'adjustment_out'::stock_movement_type end,target_quantity,trim(target_reference),auth.uid()) returning id into new_id;
  return new_id;
end; $$;

create or replace function public.record_stock_transfer(target_company uuid,source_warehouse uuid,destination_warehouse uuid,target_product uuid,target_quantity numeric,target_reference text)
returns uuid language plpgsql security definer set search_path=public as $$
declare transfer_id uuid:=gen_random_uuid();
begin
  if not has_company_permission(target_company,'inventory') then raise exception 'Inventory access denied'; end if;
  if source_warehouse=destination_warehouse then raise exception 'Source and destination warehouses must differ'; end if;
  if target_quantity<=0 then raise exception 'Quantity must be greater than zero'; end if;
  if nullif(trim(target_reference),'') is null then raise exception 'Transfer reference is required'; end if;
  if not exists(select 1 from warehouses where id=source_warehouse and company_id=target_company and active)
     or not exists(select 1 from warehouses where id=destination_warehouse and company_id=target_company and active) then
    raise exception 'Invalid transfer warehouse';
  end if;
  insert into stock_movements(company_id,warehouse_id,product_id,movement_type,quantity,source_type,source_id,reference,created_by)
  values(target_company,source_warehouse,target_product,'transfer_out',target_quantity,'stock_transfer',transfer_id,trim(target_reference),auth.uid()),
        (target_company,destination_warehouse,target_product,'transfer_in',target_quantity,'stock_transfer',transfer_id,trim(target_reference),auth.uid());
  return transfer_id;
end; $$;

revoke all on function public.record_stock_adjustment(uuid,uuid,uuid,numeric,boolean,text) from public,anon;
revoke all on function public.record_stock_transfer(uuid,uuid,uuid,uuid,numeric,text) from public,anon;
grant execute on function public.record_stock_adjustment(uuid,uuid,uuid,numeric,boolean,text) to authenticated;
grant execute on function public.record_stock_transfer(uuid,uuid,uuid,uuid,numeric,text) to authenticated;

commit;
