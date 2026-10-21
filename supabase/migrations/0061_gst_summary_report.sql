-- Monthly GST (sales tax) summary: output tax on sales less credit notes, input tax on purchases less debit notes.
begin;

create or replace function public.get_gst_summary(target_company uuid,date_from date,date_to date)
returns table(period text,sales_value numeric,output_gst numeric,purchase_value numeric,input_gst numeric,net_gst_payable numeric)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_company_member(target_company) then raise exception 'Access denied'; end if;
  if date_from is null or date_to is null or date_from>date_to then raise exception 'A valid date range is required'; end if;
  return query
  with moves as (
    select to_char(date_trunc('month',i.invoice_date),'YYYY-MM') p,i.subtotal sales,i.gst_total out_gst,0::numeric purch,0::numeric in_gst
      from public.sales_invoices i where i.company_id=target_company and i.status not in ('draft','void') and i.invoice_date between date_from and date_to
    union all
    select to_char(date_trunc('month',n.credit_date),'YYYY-MM'),-n.subtotal,-n.gst_total,0,0
      from public.sales_credit_notes n where n.company_id=target_company and n.status='posted' and n.credit_date between date_from and date_to
    union all
    select to_char(date_trunc('month',b.bill_date),'YYYY-MM'),0,0,b.subtotal,b.gst_total
      from public.purchase_bills b where b.company_id=target_company and b.status not in ('draft','void') and b.bill_date between date_from and date_to
    union all
    select to_char(date_trunc('month',d.debit_date),'YYYY-MM'),0,0,-d.subtotal,-d.gst_total
      from public.purchase_debit_notes d where d.company_id=target_company and d.status='posted' and d.debit_date between date_from and date_to
  )
  select m.p,sum(m.sales)::numeric,sum(m.out_gst)::numeric,sum(m.purch)::numeric,sum(m.in_gst)::numeric,(sum(m.out_gst)-sum(m.in_gst))::numeric
  from moves m group by m.p order by m.p;
end; $$;
revoke all on function public.get_gst_summary(uuid,date,date) from public,anon;
grant execute on function public.get_gst_summary(uuid,date,date) to authenticated;

commit;
