begin;
-- Correction is atomic: a failed copy also rolls back the original reversal.
create or replace function public.correct_sales_invoice(target_invoice uuid,target_reason text)
returns uuid language plpgsql security definer set search_path=public as $$
declare source public.sales_invoices%rowtype; draft_id uuid;
begin
  select * into source from public.sales_invoices where id=target_invoice for update;
  if source.id is null or not public.has_company_permission(source.company_id,'sales') then
    raise exception 'Invoice not found or sales access denied';
  end if;
  if source.status<>'posted' or source.amount_paid>0 then
    raise exception 'Only unpaid posted invoices can be corrected; reverse allocated receipts first';
  end if;
  if length(trim(coalesce(target_reason,'')))<3 then raise exception 'Correction reason is required'; end if;
  perform public.void_sales_invoice(source.id,target_reason);
  insert into public.sales_invoices(company_id,branch_id,customer_id,invoice_date,due_date,reference,created_by)
  values(source.company_id,source.branch_id,source.customer_id,source.invoice_date,source.due_date,
    'Correction of INV-'||source.invoice_number||': '||target_reason,auth.uid()) returning id into draft_id;
  insert into public.sales_invoice_lines(invoice_id,sales_order_line_id,product_id,description,quantity,unit_price,gst_rate)
  select draft_id,sales_order_line_id,product_id,description,quantity,unit_price,gst_rate
  from public.sales_invoice_lines where invoice_id=source.id;
  return draft_id;
end; $$;
revoke all on function public.correct_sales_invoice(uuid,text) from public,anon;
grant execute on function public.correct_sales_invoice(uuid,text) to authenticated;
commit;
