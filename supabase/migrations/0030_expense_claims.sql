-- Claims are journal-backed: expense debit / employee reimbursement liability credit.
create function public.save_expense_claim(target_company uuid, claimant text, claim_description text, expense_account uuid, payable_account uuid, claim_amount numeric, claim_date date, claim_reference text default null, target_entry uuid default null, should_post boolean default false)
returns uuid language plpgsql security invoker set search_path=public as $$
declare result uuid; existing journal_entries%rowtype;
begin
 if not public.has_company_permission(target_company,'accounting') then raise exception 'Accounting permission required'; end if;
 if nullif(trim(claimant),'') is null or nullif(trim(claim_description),'') is null then raise exception 'Claimant and description required'; end if;
 if claim_amount is null or claim_amount::text in ('NaN','Infinity','-Infinity') or claim_amount<=0 or claim_amount<>round(claim_amount,2) or claim_amount>=10000000000000000 or claim_date is null then raise exception 'Invalid amount or date'; end if;
 if not exists(select 1 from accounts where id=expense_account and company_id=target_company and active and type='expense') then raise exception 'Invalid expense account'; end if;
 if not exists(select 1 from accounts where id=payable_account and company_id=target_company and active and type='liability' and code not in ('2000','2100','2050','2200','2210','2220')) then raise exception 'Select a dedicated employee reimbursement liability account'; end if;
 if target_entry is not null then
  select * into existing from journal_entries where id=target_entry and company_id=target_company for update;
  if not found or existing.status<>'draft' or left(existing.description,16)<>'[Expense claim] ' then raise exception 'Only claim drafts can be edited'; end if;
  result:=existing.id;
  update journal_entries set entry_date=claim_date,reference=nullif(trim(claim_reference),''),description='[Expense claim] '||trim(claimant)||' — '||trim(claim_description) where id=result;
  delete from journal_lines where entry_id=result;
 else
  insert into journal_entries(company_id,entry_date,reference,description,created_by) values(target_company,claim_date,nullif(trim(claim_reference),''),'[Expense claim] '||trim(claimant)||' — '||trim(claim_description),auth.uid()) returning id into result;
 end if;
 insert into journal_lines(entry_id,account_id,description,debit,credit) values(result,expense_account,trim(claim_description),claim_amount,0),(result,payable_account,trim(claimant),0,claim_amount);
 if should_post then perform public.post_journal(result); end if;
 return result;
end $$;
revoke all on function public.save_expense_claim(uuid,text,text,uuid,uuid,numeric,date,text,uuid,boolean) from public,anon;
grant execute on function public.save_expense_claim(uuid,text,text,uuid,uuid,numeric,date,text,uuid,boolean) to authenticated;
