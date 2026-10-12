-- Full claim reimbursement. References link immutable settlement journals to claims.
create function public.settle_expense_claim(target_claim uuid, money_account uuid, settlement_date date)
returns uuid language plpgsql security invoker set search_path=public as $$
declare claim journal_entries%rowtype; result uuid; liability uuid; amount numeric; marker text;
begin
 select * into claim from journal_entries where id=target_claim for update;
 if not found or not public.has_company_permission(claim.company_id,'accounting') or claim.status<>'posted' or left(claim.description,16)<>'[Expense claim] ' then raise exception 'Posted claim not found or access denied'; end if;
 marker:='CLAIM-PAY:'||claim.id;
 if exists(select 1 from journal_entries where company_id=claim.company_id and reference=marker and status='posted') then raise exception 'Claim already reimbursed'; end if;
 if settlement_date is null or settlement_date<claim.entry_date then raise exception 'Settlement date must be on or after claim date'; end if;
 if not exists(select 1 from accounts a where a.id=money_account and a.company_id=claim.company_id and a.active and a.type='asset' and (a.code='1000' or exists(select 1 from bank_accounts b where b.company_id=claim.company_id and b.ledger_account_id=a.id and b.active))) then raise exception 'Invalid cash/bank account'; end if;
 if (select count(*) from journal_lines where entry_id=claim.id)<>2 or (select count(*) from journal_lines where entry_id=claim.id and credit>0)<>1 then raise exception 'Invalid claim lines'; end if;
 select account_id,credit into liability,amount from journal_lines where entry_id=claim.id and credit>0;
 if not exists(select 1 from accounts where id=liability and company_id=claim.company_id and active and type='liability') then raise exception 'Invalid reimbursement liability'; end if;
 insert into journal_entries(company_id,branch_id,entry_date,reference,description,created_by) values(claim.company_id,claim.branch_id,settlement_date,marker,'Expense claim reimbursement: '||claim.entry_number,auth.uid()) returning id into result;
 insert into journal_lines(entry_id,account_id,description,debit,credit) values(result,liability,'Claim liability settled',amount,0),(result,money_account,'Employee reimbursed',0,amount);
 perform public.post_journal(result);
 return result;
end $$;
revoke all on function public.settle_expense_claim(uuid,uuid,date) from public,anon;
grant execute on function public.settle_expense_claim(uuid,uuid,date) to authenticated;

create function public.guard_reimbursed_claim_reversal() returns trigger language plpgsql security invoker set search_path=public as $$
begin
 if old.status='posted' and new.status='reversed' and left(old.description,16)='[Expense claim] ' and exists(select 1 from journal_entries where company_id=old.company_id and reference='CLAIM-PAY:'||old.id and status='posted') then raise exception 'Reverse the reimbursement before reversing this claim'; end if;
 return new;
end $$;
create trigger guard_reimbursed_claim_reversal before update of status on public.journal_entries for each row execute function public.guard_reimbursed_claim_reversal();
