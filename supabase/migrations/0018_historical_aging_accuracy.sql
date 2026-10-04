-- Historical receivable/payable aging must only include documents and allocated
-- payments that existed on the requested as-of date.

begin;

create or replace function public.get_receivable_aging(target_company uuid,as_of date default current_date)
returns table(contact_name text,current_amount numeric,days_1_30 numeric,days_31_60 numeric,days_61_90 numeric,days_over_90 numeric,total_due numeric)
language plpgsql stable security definer set search_path=public as $$
begin
  if as_of is null then raise exception 'As-of date is required'; end if;
  if not public.is_company_member(target_company) then raise exception 'Access denied'; end if;
  return query
  with document_balances as (
    select i.customer_id,i.due_date,
      greatest(i.total-coalesce(sum(p.amount) filter(where p.status='posted' and p.direction='receipt' and p.payment_date<=as_of),0),0)::numeric balance
    from public.sales_invoices i
    left join public.payments p on p.sales_invoice_id=i.id and p.company_id=i.company_id
    where i.company_id=target_company and i.invoice_date<=as_of and i.status in ('posted','paid')
    group by i.id,i.customer_id,i.due_date,i.total
  )
  select c.name,
    coalesce(sum(d.balance) filter(where as_of-d.due_date<=0),0),
    coalesce(sum(d.balance) filter(where as_of-d.due_date between 1 and 30),0),
    coalesce(sum(d.balance) filter(where as_of-d.due_date between 31 and 60),0),
    coalesce(sum(d.balance) filter(where as_of-d.due_date between 61 and 90),0),
    coalesce(sum(d.balance) filter(where as_of-d.due_date>90),0),sum(d.balance)
  from document_balances d join public.contacts c on c.id=d.customer_id and c.company_id=target_company
  where d.balance>0 group by c.id,c.name order by c.name;
end; $$;

create or replace function public.get_payable_aging(target_company uuid,as_of date default current_date)
returns table(contact_name text,current_amount numeric,days_1_30 numeric,days_31_60 numeric,days_61_90 numeric,days_over_90 numeric,total_due numeric)
language plpgsql stable security definer set search_path=public as $$
begin
  if as_of is null then raise exception 'As-of date is required'; end if;
  if not public.is_company_member(target_company) then raise exception 'Access denied'; end if;
  return query
  with document_balances as (
    select b.supplier_id,b.due_date,
      greatest(b.total-coalesce(sum(p.amount) filter(where p.status='posted' and p.direction='payment' and p.payment_date<=as_of),0),0)::numeric balance
    from public.purchase_bills b
    left join public.payments p on p.purchase_bill_id=b.id and p.company_id=b.company_id
    where b.company_id=target_company and b.bill_date<=as_of and b.status in ('posted','part_paid','paid')
    group by b.id,b.supplier_id,b.due_date,b.total
  )
  select c.name,
    coalesce(sum(d.balance) filter(where as_of-d.due_date<=0),0),
    coalesce(sum(d.balance) filter(where as_of-d.due_date between 1 and 30),0),
    coalesce(sum(d.balance) filter(where as_of-d.due_date between 31 and 60),0),
    coalesce(sum(d.balance) filter(where as_of-d.due_date between 61 and 90),0),
    coalesce(sum(d.balance) filter(where as_of-d.due_date>90),0),sum(d.balance)
  from document_balances d join public.contacts c on c.id=d.supplier_id and c.company_id=target_company
  where d.balance>0 group by c.id,c.name order by c.name;
end; $$;

revoke all on function public.get_receivable_aging(uuid,date) from public,anon;
revoke all on function public.get_payable_aging(uuid,date) from public,anon;
grant execute on function public.get_receivable_aging(uuid,date) to authenticated;
grant execute on function public.get_payable_aging(uuid,date) to authenticated;

commit;
