begin;
-- Full claim reimbursement. References link immutable settlement journals to claims.
create function public.settle_expense_claim_partial(target_claim uuid, money_account uuid, settlement_date date, payment_amount numeric, request_id uuid default gen_random_uuid())
returns uuid language plpgsql security invoker set search_path=public as $$
declare claim journal_entries%rowtype; result uuid; liability uuid; amount numeric; marker text; paid numeric;
begin
 select * into claim from journal_entries where id=target_claim for update;
 if not found or not public.has_company_permission(claim.company_id,'accounting') or claim.status<>'posted' or left(claim.description,16)<>'[Expense claim] ' then raise exception 'Posted claim not found or access denied'; end if;
 marker:='CLAIM-PAY:'||claim.id;
 if payment_amount is null or payment_amount::text in ('NaN','Infinity','-Infinity') or payment_amount<=0 or payment_amount<>round(payment_amount,2) or request_id is null then raise exception 'Invalid payment amount or request';end if;
 if exists(select 1 from journal_entries where id=request_id) then
  if exists(select 1 from journal_entries e where e.id=request_id and e.company_id=claim.company_id and e.reference=marker and e.entry_date=settlement_date and e.status='posted' and (select sum(debit) from journal_lines where entry_id=e.id)=payment_amount and exists(select 1 from journal_lines where entry_id=e.id and account_id=money_account and credit=payment_amount)) then return request_id;end if;
  raise exception 'Payment request already used';
 end if;
 if settlement_date is null or settlement_date<claim.entry_date then raise exception 'Settlement date must be on or after claim date'; end if;
 if not exists(select 1 from accounts a where a.id=money_account and a.company_id=claim.company_id and a.active and a.type='asset' and (a.code='1000' or exists(select 1 from bank_accounts b where b.company_id=claim.company_id and b.ledger_account_id=a.id and b.active))) then raise exception 'Invalid cash/bank account'; end if;
 if (select count(*) from journal_lines where entry_id=claim.id)<>2 or (select count(*) from journal_lines where entry_id=claim.id and credit>0)<>1 then raise exception 'Invalid claim lines'; end if;
 select account_id,credit into liability,amount from journal_lines where entry_id=claim.id and credit>0;
 select coalesce(sum(l.debit),0) into paid from journal_entries e join journal_lines l on l.entry_id=e.id where e.company_id=claim.company_id and e.reference=marker and e.status='posted' and l.account_id=liability;
 if payment_amount>amount-paid then raise exception 'Payment exceeds remaining claim balance';end if;
 if not exists(select 1 from accounts where id=liability and company_id=claim.company_id and active and type='liability') then raise exception 'Invalid reimbursement liability'; end if;
 insert into journal_entries(id,company_id,branch_id,entry_date,reference,description,created_by) values(request_id,claim.company_id,claim.branch_id,settlement_date,marker,'Expense claim reimbursement: '||claim.entry_number,auth.uid()) returning id into result;
 insert into journal_lines(entry_id,account_id,description,debit,credit) values(result,liability,'Claim liability settled',payment_amount,0),(result,money_account,'Employee reimbursed',0,payment_amount);
 perform public.post_journal(result);
 return result;
end $$;

create or replace function public.settle_expense_claim(target_claim uuid,money_account uuid,settlement_date date) returns uuid language plpgsql security invoker set search_path=public as $$
declare claim journal_entries%rowtype; total numeric; paid numeric;
begin
 select * into claim from journal_entries where id=target_claim for update;
 if not found or not has_company_permission(claim.company_id,'accounting') then raise exception 'Access denied';end if;
 select sum(credit) into total from journal_lines where entry_id=claim.id;
 select coalesce(sum(l.debit),0) into paid from journal_entries e join journal_lines l on l.entry_id=e.id where e.company_id=claim.company_id and e.reference='CLAIM-PAY:'||claim.id and e.status='posted';
 return settle_expense_claim_partial(claim.id,money_account,settlement_date,total-paid);
end $$;
revoke all on function public.settle_expense_claim_partial(uuid,uuid,date,numeric,uuid) from public,anon;
grant execute on function public.settle_expense_claim_partial(uuid,uuid,date,numeric,uuid) to authenticated;
commit;
