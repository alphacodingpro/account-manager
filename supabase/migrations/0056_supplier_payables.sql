-- Per-supplier payable balance for the Suppliers page.
-- Uses the same rules as get_payable_aging: posted bills less posted payments and
-- posted debit notes dated on or before the as-of date. Returns suppliers by id so
-- two contacts with the same name are never merged.

begin;

create or replace function public.get_supplier_payables(target_company uuid,as_of date default current_date)
returns table(supplier_id uuid,open_bills integer,overdue_amount numeric,total_due numeric)
language plpgsql stable security definer set search_path=public as $$
begin
  if as_of is null then raise exception 'As-of date is required'; end if;
  if not public.is_company_member(target_company) then raise exception 'Access denied'; end if;
  return query with document_balances as (
    select b.supplier_id,b.due_date,greatest(b.total
      -coalesce((select sum(p.amount) from public.payments p where p.purchase_bill_id=b.id and p.company_id=b.company_id and p.status='posted' and p.direction='payment' and p.payment_date<=as_of),0)
      -coalesce((select sum(n.total) from public.purchase_debit_notes n where n.bill_id=b.id and n.company_id=b.company_id and n.status='posted' and n.debit_date<=as_of),0),0)::numeric balance
    from public.purchase_bills b
    where b.company_id=target_company and b.bill_date<=as_of and b.status in ('posted','part_paid','paid')
  )
  select d.supplier_id,count(*)::integer,
    coalesce(sum(d.balance) filter(where d.due_date<as_of),0)::numeric,
    sum(d.balance)::numeric
  from document_balances d
  where d.balance>0 and d.supplier_id is not null
  group by d.supplier_id;
end; $$;

revoke all on function public.get_supplier_payables(uuid,date) from public,anon;
grant execute on function public.get_supplier_payables(uuid,date) to authenticated;

commit;
