-- Atomic bank/cash transfers reuse the existing protected journal posting path.
create function public.create_inter_account_transfer(target_company uuid, source_account uuid, destination_account uuid, transfer_amount numeric, transfer_date date, target_branch uuid default null, transfer_reference text default null)
returns uuid language plpgsql security invoker set search_path=public as $$
declare result uuid;
begin
  if not public.has_company_permission(target_company,'accounting') then raise exception 'Accounting permission required'; end if;
  if source_account=destination_account or source_account is null or destination_account is null then raise exception 'Select two different cash/bank accounts'; end if;
  if transfer_amount is null or transfer_amount::text in ('NaN','Infinity','-Infinity') or transfer_amount<=0 or transfer_amount<>round(transfer_amount,2) or transfer_amount>=10000000000000000 then raise exception 'Invalid transfer amount'; end if;
  if transfer_date is null then raise exception 'Transfer date required'; end if;
  if target_branch is not null and not exists(select 1 from branches where id=target_branch and company_id=target_company and active) then raise exception 'Invalid branch'; end if;
  if (select count(*) from accounts a where a.id in(source_account,destination_account) and a.company_id=target_company and a.active and a.type='asset' and (a.code='1000' or exists(select 1 from bank_accounts b where b.company_id=target_company and b.ledger_account_id=a.id and b.active)))<>2 then raise exception 'Invalid cash/bank accounts'; end if;
  insert into journal_entries(company_id,branch_id,entry_date,reference,description,created_by) values(target_company,target_branch,transfer_date,nullif(trim(transfer_reference),''),'Inter account transfer',auth.uid()) returning id into result;
  insert into journal_lines(entry_id,account_id,debit,credit) values(result,destination_account,transfer_amount,0),(result,source_account,0,transfer_amount);
  perform public.post_journal(result);
  return result;
end $$;
revoke all on function public.create_inter_account_transfer(uuid,uuid,uuid,numeric,date,uuid,text) from public,anon;
grant execute on function public.create_inter_account_transfer(uuid,uuid,uuid,numeric,date,uuid,text) to authenticated;
