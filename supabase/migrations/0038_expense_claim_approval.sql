begin;
create function public.expense_claim_fingerprint(target_entry uuid) returns text language sql stable security invoker set search_path=public as $$
 select md5((to_jsonb(e)-'status'-'posted_by'-'posted_at')::text||coalesce((select jsonb_agg(to_jsonb(l) order by l.id)::text from journal_lines l where l.entry_id=e.id),'[]')) from journal_entries e where e.id=target_entry;
$$;
create table public.expense_claim_approvals (
 id uuid primary key default gen_random_uuid(),company_id uuid not null references companies(id),entry_id uuid not null references journal_entries(id) on delete cascade,fingerprint text not null,approved_by uuid not null default auth.uid() references auth.users(id),approved_at timestamptz not null default now(),unique(entry_id,fingerprint)
);
alter table public.expense_claim_approvals enable row level security;
create policy "claim approval read" on public.expense_claim_approvals for select using(has_company_permission(company_id,'accounting'));
create policy "claim owner approval" on public.expense_claim_approvals for insert with check(has_company_permission(company_id,'admin') and approved_by=auth.uid());
create function public.validate_expense_claim_approval() returns trigger language plpgsql security invoker set search_path=public as $$
declare entry journal_entries%rowtype;
begin
 select * into entry from journal_entries where id=new.entry_id for update;
 if not found or entry.company_id<>new.company_id or entry.status<>'draft' or left(entry.description,16)<>'[Expense claim] ' then raise exception 'Only claim drafts may be approved';end if;
 if not has_company_permission(entry.company_id,'admin') or new.approved_by<>auth.uid() then raise exception 'Owner/admin approval required';end if;
 if (select count(*) from journal_lines where entry_id=entry.id)<>2 or (select sum(debit-credit) from journal_lines where entry_id=entry.id)<>0 or (select sum(debit) from journal_lines where entry_id=entry.id)<=0 then raise exception 'Claim needs balanced positive lines';end if;
 new.fingerprint:=expense_claim_fingerprint(entry.id);new.approved_at:=now();return new;
end $$;
create trigger expense_approval_validate before insert on expense_claim_approvals for each row execute function validate_expense_claim_approval();
create trigger expense_approval_audit after insert on expense_claim_approvals for each row execute function write_audit_log();
create function public.approve_expense_claim(target_entry uuid) returns uuid language plpgsql security invoker set search_path=public as $$
declare entry journal_entries%rowtype; result uuid; current_fingerprint text;
begin
 select * into entry from journal_entries where id=target_entry for update;
 if not found or not has_company_permission(entry.company_id,'admin') or entry.status<>'draft' or left(entry.description,16)<>'[Expense claim] ' then raise exception 'Owner/admin approval of a claim draft required';end if;
 current_fingerprint:=expense_claim_fingerprint(entry.id);
 select id into result from expense_claim_approvals where entry_id=entry.id and fingerprint=current_fingerprint;
 if found then return result;end if;
 insert into expense_claim_approvals(company_id,entry_id,fingerprint) values(entry.company_id,entry.id,current_fingerprint) returning id into result;return result;
end $$;
create function public.guard_unapproved_claim_posting() returns trigger language plpgsql security invoker set search_path=public as $$
begin
 if tg_op='INSERT' then
  if new.status<>'draft' and left(new.description,16)='[Expense claim] ' then raise exception 'Claims must be created as drafts';end if;return new;
 end if;
 if left(old.description,16)='[Expense claim] ' and left(new.description,16) is distinct from '[Expense claim] ' then raise exception 'Expense claim identity cannot be removed';end if;
 if old.status='draft' and new.status='posted' and (left(old.description,16)='[Expense claim] ' or left(new.description,16)='[Expense claim] ') and (to_jsonb(new)-'status'-'posted_by'-'posted_at')<>(to_jsonb(old)-'status'-'posted_by'-'posted_at') then raise exception 'Save claim changes and obtain new approval before posting';end if;
 if old.status='draft' and new.status='posted' and (left(old.description,16)='[Expense claim] ' or left(new.description,16)='[Expense claim] ') and not exists(select 1 from expense_claim_approvals where company_id=old.company_id and entry_id=old.id and fingerprint=expense_claim_fingerprint(old.id)) then raise exception 'Owner/admin must approve the current claim before posting';end if;return new;
end $$;
create trigger claim_approval_posting_guard before insert or update on journal_entries for each row execute function guard_unapproved_claim_posting();
revoke all on function public.approve_expense_claim(uuid) from public,anon;
grant execute on function public.approve_expense_claim(uuid) to authenticated;
commit;
