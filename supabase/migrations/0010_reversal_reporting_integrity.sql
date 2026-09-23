-- A reversed journal still represents a posted historical transaction.
-- Include both the original and its opposite entry so balances net to zero.
begin;

create or replace function public.get_trial_balance(target_company uuid,date_from date default null,date_to date default current_date)
returns table(account_code text,account_name text,account_type public.account_type,debit numeric,credit numeric,balance numeric)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_company_member(target_company) then raise exception 'Access denied'; end if;
  return query select a.code,a.name,a.type,
    coalesce(sum(case when e.id is not null then l.debit else 0 end),0),
    coalesce(sum(case when e.id is not null then l.credit else 0 end),0),
    case when a.type in ('asset','expense') then coalesce(sum(case when e.id is not null then l.debit-l.credit else 0 end),0) else coalesce(sum(case when e.id is not null then l.credit-l.debit else 0 end),0) end
  from accounts a left join journal_lines l on l.account_id=a.id
  left join journal_entries e on e.id=l.entry_id and e.company_id=target_company
    and e.status in ('posted','reversed')
    and (date_from is null or e.entry_date>=date_from) and e.entry_date<=date_to
  where a.company_id=target_company group by a.id order by a.code;
end; $$;

create or replace function public.get_general_ledger(target_company uuid,date_from date,date_to date)
returns table(entry_date date,reference text,description text,account_code text,account_name text,debit numeric,credit numeric,running_balance numeric)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_company_member(target_company) then raise exception 'Access denied'; end if;
  return query select e.entry_date,e.reference,coalesce(l.description,e.description),a.code,a.name,l.debit,l.credit,
    sum(case when a.type in ('asset','expense') then l.debit-l.credit else l.credit-l.debit end) over(partition by a.id order by e.entry_date,e.entry_number,l.id)
  from journal_entries e join journal_lines l on l.entry_id=e.id join accounts a on a.id=l.account_id and a.company_id=e.company_id
  where e.company_id=target_company and e.status in ('posted','reversed')
    and e.entry_date between date_from and date_to order by e.entry_date,e.entry_number;
end; $$;

create or replace function public.get_profit_loss(target_company uuid,date_from date,date_to date)
returns table(account_code text,account_name text,category text,amount numeric)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_company_member(target_company) then raise exception 'Access denied'; end if;
  return query select a.code,a.name,a.type::text,
    case when a.type='income' then coalesce(sum(case when e.id is not null then l.credit-l.debit else 0 end),0) else coalesce(sum(case when e.id is not null then l.debit-l.credit else 0 end),0) end
  from accounts a left join journal_lines l on l.account_id=a.id
  left join journal_entries e on e.id=l.entry_id and e.company_id=target_company
    and e.status in ('posted','reversed') and e.entry_date between date_from and date_to
  where a.company_id=target_company and a.type in ('income','expense') group by a.id order by a.type,a.code;
end; $$;

create or replace function public.get_balance_sheet(target_company uuid,as_of date default current_date)
returns table(account_code text,account_name text,category text,amount numeric)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_company_member(target_company) then raise exception 'Access denied'; end if;
  return query select a.code,a.name,a.type::text,
    case when a.type='asset' then coalesce(sum(case when e.id is not null then l.debit-l.credit else 0 end),0) else coalesce(sum(case when e.id is not null then l.credit-l.debit else 0 end),0) end
  from accounts a left join journal_lines l on l.account_id=a.id
  left join journal_entries e on e.id=l.entry_id and e.company_id=target_company
    and e.status in ('posted','reversed') and e.entry_date<=as_of
  where a.company_id=target_company and a.type in ('asset','liability','equity') group by a.id order by a.type,a.code;
end; $$;

create or replace function public.get_dashboard_summary(target_company uuid)
returns jsonb language plpgsql stable security definer set search_path=public
as $$
declare result jsonb;
begin
  if not is_company_member(target_company) then raise exception 'Access denied'; end if;
  with balances as (
    select a.code,a.type,
      coalesce(sum(case when e.status in ('posted','reversed') then l.debit else 0 end),0) debit,
      coalesce(sum(case when e.status in ('posted','reversed') then l.credit else 0 end),0) credit
    from accounts a left join journal_lines l on l.account_id=a.id
    left join journal_entries e on e.id=l.entry_id and e.company_id=target_company
    where a.company_id=target_company group by a.id,a.code,a.type
  ), totals as (
    select
      coalesce(sum(case when code='1000' then debit-credit else 0 end),0) cash_balance,
      coalesce(sum(case when code='1100' then debit-credit else 0 end),0) receivables,
      coalesce(sum(case when code='2000' then credit-debit else 0 end),0) payables,
      coalesce(sum(case when type='income' then credit-debit else 0 end),0) income,
      coalesce(sum(case when type='expense' then debit-credit else 0 end),0) expenses
    from balances
  ), invoice_stats as (
    select count(*) filter(where status in ('posted','paid')) invoice_count,
      count(*) filter(where status='posted' and due_date<current_date and amount_paid<total) overdue_count,
      coalesce(sum(total) filter(where status in ('posted','paid')),0) sales_total
    from sales_invoices where company_id=target_company
  ), recent as (
    select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) items from (
      select e.id,e.entry_date,e.reference,e.description,e.status,coalesce(sum(l.debit),0) amount
      from journal_entries e join journal_lines l on l.entry_id=e.id
      where e.company_id=target_company and e.status in ('posted','reversed')
      group by e.id order by e.entry_date desc,e.entry_number desc limit 8
    ) x
  ), monthly as (
    select coalesce(jsonb_agg(to_jsonb(m) order by m.month_start),'[]'::jsonb) items from (
      select month_start,to_char(month_start,'Mon') label,
        coalesce(sum(case when a.type='income' then l.credit-l.debit else 0 end),0) income,
        coalesce(sum(case when a.type='expense' then l.debit-l.credit else 0 end),0) expenses
      from generate_series(date_trunc('month',current_date)-interval '5 months',date_trunc('month',current_date),interval '1 month') month_start
      left join journal_entries e on date_trunc('month',e.entry_date)=month_start
        and e.company_id=target_company and e.status in ('posted','reversed')
      left join journal_lines l on l.entry_id=e.id left join accounts a on a.id=l.account_id and a.company_id=target_company
      group by month_start
    ) m
  )
  select jsonb_build_object(
    'cash_balance',t.cash_balance,'receivables',t.receivables,'payables',t.payables,
    'income',t.income,'expenses',t.expenses,'net_profit',t.income-t.expenses,
    'invoice_count',i.invoice_count,'overdue_count',i.overdue_count,'sales_total',i.sales_total,
    'recent_transactions',r.items,'monthly_trend',m.items
  ) into result from totals t cross join invoice_stats i cross join recent r cross join monthly m;
  return result;
end; $$;

commit;
