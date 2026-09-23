-- Direct-method cash flow built from posted and reversed journal history.
-- Transfers between company cash/bank accounts have no effect on net cash.
begin;

create or replace function public.get_cash_flow(target_company uuid,date_from date,date_to date)
returns table(section text,line_item text,amount numeric,sort_order integer)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_company_member(target_company) then raise exception 'Access denied'; end if;
  if date_from is null or date_to is null or date_from>date_to then raise exception 'Invalid reporting period'; end if;

  return query
  with cash_accounts as (
    select a.id from accounts a where a.company_id=target_company and a.code='1000'
    union
    select b.ledger_account_id from bank_accounts b where b.company_id=target_company
  ), opening as (
    select coalesce(sum(l.debit-l.credit),0)::numeric value
    from journal_entries e join journal_lines l on l.entry_id=e.id
    where e.company_id=target_company and e.status in ('posted','reversed') and e.entry_date<date_from
      and l.account_id in (select id from cash_accounts)
  ), movements as (
    select
      case
        when a.type in ('income','expense') or a.code in ('1100','1150','1200','2000','2050','2100','2200','2210','2220') then 'Operating activities'
        when a.type='asset' then 'Investing activities'
        else 'Financing activities'
      end activity,
      a.code||' — '||a.name item,
      sum(l.credit-l.debit)::numeric value
    from journal_entries e
    join journal_lines l on l.entry_id=e.id
    join accounts a on a.id=l.account_id and a.company_id=target_company
    where e.company_id=target_company and e.status in ('posted','reversed')
      and e.entry_date between date_from and date_to
      and l.account_id not in (select id from cash_accounts)
      and exists (
        select 1 from journal_lines money_line
        where money_line.entry_id=e.id and money_line.account_id in (select id from cash_accounts)
      )
    group by activity,a.id,a.code,a.name
    having sum(l.credit-l.debit)<>0
  ), activity_rows as (
    select m.activity section,m.item line_item,m.value amount,
      case m.activity when 'Operating activities' then 110 when 'Investing activities' then 210 else 310 end
      + row_number() over(partition by m.activity order by m.item)::integer sort_order
    from movements m
  ), totals as (
    select
      coalesce(sum(value) filter(where activity='Operating activities'),0)::numeric operating,
      coalesce(sum(value) filter(where activity='Investing activities'),0)::numeric investing,
      coalesce(sum(value) filter(where activity='Financing activities'),0)::numeric financing
    from movements
  ), report(section,line_item,amount,sort_order) as (
    select 'Cash position'::text,'Opening cash and bank balance'::text,o.value,10 from opening o
    union all select ar.section,ar.line_item,ar.amount,ar.sort_order from activity_rows ar
    union all select 'Operating activities','Net cash from operating activities',t.operating,190 from totals t
    union all select 'Investing activities','Net cash from investing activities',t.investing,290 from totals t
    union all select 'Financing activities','Net cash from financing activities',t.financing,390 from totals t
    union all select 'Cash position','Net increase / (decrease) in cash',t.operating+t.investing+t.financing,410 from totals t
    union all select 'Cash position','Closing cash and bank balance',o.value+t.operating+t.investing+t.financing,420 from opening o cross join totals t
  )
  select r.section,r.line_item,r.amount,r.sort_order from report r order by r.sort_order;
end; $$;

revoke all on function public.get_cash_flow(uuid,date,date) from public,anon;
grant execute on function public.get_cash_flow(uuid,date,date) to authenticated;

commit;
