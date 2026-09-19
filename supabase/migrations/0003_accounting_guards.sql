create or replace function public.can_write_company(target_company uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists(
    select 1 from company_members
    where company_id=target_company and user_id=auth.uid() and active
      and role in ('owner','admin','accountant')
  );
$$;

create or replace function public.validate_journal_line_company()
returns trigger language plpgsql set search_path = public
as $$
declare entry_company uuid; account_company uuid;
begin
  select company_id into entry_company from journal_entries where id=new.entry_id;
  select company_id into account_company from accounts where id=new.account_id;
  if entry_company is null or account_company is null or entry_company <> account_company then
    raise exception 'Journal account must belong to the same company';
  end if;
  return new;
end; $$;

drop trigger if exists journal_line_company_guard on public.journal_lines;
create trigger journal_line_company_guard before insert or update on public.journal_lines
for each row execute function public.validate_journal_line_company();

create or replace function public.post_journal(target_entry uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare target_company uuid; total_debit numeric(18,2); total_credit numeric(18,2); line_count integer;
begin
  select company_id into target_company from journal_entries where id=target_entry and status='draft' for update;
  if target_company is null or not can_write_company(target_company) then
    raise exception 'Entry not found or posting access denied';
  end if;
  select count(*),coalesce(sum(debit),0),coalesce(sum(credit),0)
    into line_count,total_debit,total_credit from journal_lines where entry_id=target_entry;
  if line_count < 2 then raise exception 'At least two lines are required'; end if;
  if total_debit <= 0 or total_debit <> total_credit then raise exception 'Journal entry is not balanced'; end if;
  update journal_entries set status='posted',posted_by=auth.uid(),posted_at=now() where id=target_entry;
end; $$;

drop policy if exists "member accounts" on public.accounts;
create policy "members read accounts" on public.accounts for select using(public.is_company_member(company_id));
create policy "writers insert accounts" on public.accounts for insert with check(public.can_write_company(company_id));
create policy "writers update accounts" on public.accounts for update using(public.can_write_company(company_id)) with check(public.can_write_company(company_id));
create policy "writers delete accounts" on public.accounts for delete using(public.can_write_company(company_id));

drop policy if exists "member journals" on public.journal_entries;
create policy "members read journals" on public.journal_entries for select using(public.is_company_member(company_id));
create policy "writers insert journals" on public.journal_entries for insert with check(public.can_write_company(company_id));
create policy "writers update journals" on public.journal_entries for update using(public.can_write_company(company_id)) with check(public.can_write_company(company_id));
create policy "writers delete journals" on public.journal_entries for delete using(public.can_write_company(company_id));

drop policy if exists "member journal lines" on public.journal_lines;
create policy "members read journal lines" on public.journal_lines for select
using(exists(select 1 from journal_entries e where e.id=entry_id and public.is_company_member(e.company_id)));
create policy "writers insert journal lines" on public.journal_lines for insert
with check(exists(select 1 from journal_entries e where e.id=entry_id and public.can_write_company(e.company_id)));
create policy "writers update journal lines" on public.journal_lines for update
using(exists(select 1 from journal_entries e where e.id=entry_id and public.can_write_company(e.company_id)));
create policy "writers delete journal lines" on public.journal_lines for delete
using(exists(select 1 from journal_entries e where e.id=entry_id and public.can_write_company(e.company_id)));

grant execute on function public.can_write_company(uuid) to authenticated;
