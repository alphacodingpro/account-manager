create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles(id,full_name)
  values(new.id,coalesce(new.raw_user_meta_data->>'full_name',''))
  on conflict(id) do nothing;
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

insert into public.profiles(id,full_name)
select id,coalesce(raw_user_meta_data->>'full_name','') from auth.users
on conflict(id) do nothing;

create policy "owners update company" on public.companies for update
using(exists(select 1 from public.company_members m where m.company_id=id and m.user_id=auth.uid() and m.role in ('owner','admin') and m.active))
with check(exists(select 1 from public.company_members m where m.company_id=id and m.user_id=auth.uid() and m.role in ('owner','admin') and m.active));

