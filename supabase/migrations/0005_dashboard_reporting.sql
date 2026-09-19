create or replace function public.get_dashboard_summary(target_company uuid)
returns jsonb language plpgsql stable security definer set search_path=public
as $$
declare result jsonb;
begin
  if not is_company_member(target_company) then raise exception 'Access denied'; end if;
  with balances as (
    select a.code,a.type,
      coalesce(sum(case when e.status='posted' then l.debit else 0 end),0) debit,
      coalesce(sum(case when e.status='posted' then l.credit else 0 end),0) credit
    from accounts a
    left join journal_lines l on l.account_id=a.id
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
      select e.id,e.entry_date,e.reference,e.description,e.status,
        coalesce(sum(l.debit),0) amount
      from journal_entries e join journal_lines l on l.entry_id=e.id
      where e.company_id=target_company and e.status='posted'
      group by e.id order by e.entry_date desc,e.entry_number desc limit 8
    ) x
  ), monthly as (
    select coalesce(jsonb_agg(to_jsonb(m) order by m.month_start),'[]'::jsonb) items from (
      select month_start,
        to_char(month_start,'Mon') label,
        coalesce(sum(case when a.type='income' then l.credit-l.debit else 0 end),0) income,
        coalesce(sum(case when a.type='expense' then l.debit-l.credit else 0 end),0) expenses
      from generate_series(date_trunc('month',current_date)-interval '5 months',date_trunc('month',current_date),interval '1 month') month_start
      left join journal_entries e on date_trunc('month',e.entry_date)=month_start and e.company_id=target_company and e.status='posted'
      left join journal_lines l on l.entry_id=e.id
      left join accounts a on a.id=l.account_id
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
grant execute on function public.get_dashboard_summary(uuid) to authenticated;
