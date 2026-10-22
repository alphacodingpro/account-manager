-- Customer / supplier statements of account and a General Ledger report. Read-only; nothing is posted.
begin;

-- Statement for one customer or supplier: opening balance, then each document with a running balance.
-- Customer: invoices add, receipts and credit notes reduce. Supplier: bills add, payments and debit notes reduce.
create or replace function public.get_contact_statement(target_company uuid,target_contact uuid,date_from date,date_to date)
returns table(line_no integer,txn_date date,doc_type text,doc_number text,reference text,charges numeric,payments numeric,balance numeric)
language plpgsql stable security definer set search_path=public as $$
declare k text;
begin
  if not is_company_member(target_company) then raise exception 'Access denied'; end if;
  if date_from is null or date_to is null or date_from>date_to then raise exception 'A valid date range is required'; end if;
  select c.kind::text into k from public.contacts c where c.id=target_contact and c.company_id=target_company;
  if k is null then raise exception 'Contact not found'; end if;
  return query
  with docs as (
    select b.bill_date d,'Bill'::text t,'BILL-'||lpad(b.bill_number::text,6,'0') n,b.supplier_reference r,b.total ch,0::numeric pay,1 ord
      from public.purchase_bills b where k='supplier' and b.company_id=target_company and b.supplier_id=target_contact and b.status not in ('draft','void') and b.bill_date<=date_to
    union all
    select p.payment_date,'Payment','PAY-'||lpad(p.payment_number::text,6,'0'),p.reference,0::numeric,p.amount,2
      from public.payments p where k='supplier' and p.company_id=target_company and p.contact_id=target_contact and p.status='posted' and p.direction='payment' and p.payment_date<=date_to
    union all
    select d.debit_date,'Debit note','DN-'||lpad(d.debit_number::text,6,'0'),d.reason,0::numeric,d.total,3
      from public.purchase_debit_notes d where k='supplier' and d.company_id=target_company and d.supplier_id=target_contact and d.status='posted' and d.debit_date<=date_to
    union all
    select i.invoice_date,'Invoice','INV-'||lpad(i.invoice_number::text,6,'0'),i.reference,i.total,0::numeric,1
      from public.sales_invoices i where k<>'supplier' and i.company_id=target_company and i.customer_id=target_contact and i.status not in ('draft','void') and i.invoice_date<=date_to
    union all
    select p.payment_date,'Receipt','PAY-'||lpad(p.payment_number::text,6,'0'),p.reference,0::numeric,p.amount,2
      from public.payments p where k<>'supplier' and p.company_id=target_company and p.contact_id=target_contact and p.status='posted' and p.direction='receipt' and p.payment_date<=date_to
    union all
    select n.credit_date,'Credit note','CN-'||lpad(n.credit_number::text,6,'0'),n.reason,0::numeric,n.total,3
      from public.sales_credit_notes n where k<>'supplier' and n.company_id=target_company and n.customer_id=target_contact and n.status='posted' and n.credit_date<=date_to
  ), opening as (select coalesce(sum(x.ch-x.pay),0) bal from docs x where x.d<date_from)
  select 0,date_from,'Opening balance'::text,''::text,''::text,0::numeric,0::numeric,(select bal from opening)
  union all
  select (row_number() over (order by x.d,x.ord,x.n))::integer,x.d,x.t,x.n,x.r,x.ch,x.pay,
         (select bal from opening)+sum(x.ch-x.pay) over (order by x.d,x.ord,x.n rows between unbounded preceding and current row)
  from docs x where x.d>=date_from
  order by 1;
end; $$;
revoke all on function public.get_contact_statement(uuid,uuid,date,date) from public,anon;
grant execute on function public.get_contact_statement(uuid,uuid,date,date) to authenticated;

-- General Ledger: every posted line per account with a running balance (all accounts or one).
create or replace function public.get_account_ledger(target_company uuid,date_from date,date_to date,target_account uuid default null)
returns table(account_code text,account_name text,entry_date date,entry_number text,reference text,description text,debit numeric,credit numeric,balance numeric)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_company_member(target_company) then raise exception 'Access denied'; end if;
  if date_from is null or date_to is null or date_from>date_to then raise exception 'A valid date range is required'; end if;
  return query
  with lines as (
    select a.id aid,a.code ac,a.name an,a.type at,e.entry_date ed,e.entry_number en,e.reference er,coalesce(nullif(l.description,''),e.description) ds,l.debit dr,l.credit cr,l.id lid
    from public.journal_lines l join public.journal_entries e on e.id=l.entry_id join public.accounts a on a.id=l.account_id
    where e.company_id=target_company and e.status in ('posted','reversed') and e.entry_date<=date_to
      and (target_account is null or a.id=target_account)
  ), opening as (
    select aid,ac,an,at,coalesce(sum(case when at in ('asset','expense') then dr-cr else cr-dr end),0) bal from lines where ed<date_from group by aid,ac,an,at
  ), moving as (
    select l.*,coalesce(o.bal,0)+sum(case when l.at in ('asset','expense') then l.dr-l.cr else l.cr-l.dr end) over (partition by l.aid order by l.ed,l.en,l.lid rows between unbounded preceding and current row) run
    from lines l left join opening o on o.aid=l.aid where l.ed>=date_from
  ), heads as (
    select o.ac,o.an,date_from d,0 en,'Opening balance'::text er,''::text ds,0::numeric dr,0::numeric cr,o.bal run,0 sortk from opening o
    union select m.ac,m.an,date_from,0,'Opening balance','',0,0,0::numeric,0 from moving m where not exists(select 1 from opening o where o.aid=m.aid) group by m.ac,m.an
  )
  select u.ac,u.an,u.d,case when u.sortk=0 then '' else 'JV-'||lpad(u.en::text,6,'0') end,u.er,u.ds,u.dr,u.cr,u.run from (
    select h.ac,h.an,h.d,h.en,h.er,h.ds,h.dr,h.cr,h.run,h.sortk from heads h
    union all select m.ac,m.an,m.ed,m.en,m.er,m.ds,m.dr,m.cr,m.run,1 from moving m
  ) u order by u.ac,u.sortk,u.d,u.en;
end; $$;
revoke all on function public.get_account_ledger(uuid,date,date,uuid) from public,anon;
grant execute on function public.get_account_ledger(uuid,date,date,uuid) to authenticated;

commit;
