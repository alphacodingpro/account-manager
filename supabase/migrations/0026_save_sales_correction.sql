begin;
create or replace function public.save_sales_invoice_correction(target_invoice uuid,header jsonb,items jsonb,should_post boolean)
returns uuid language plpgsql security invoker set search_path=public as $$
declare draft_id uuid; target_company uuid;
begin
  select company_id into target_company from public.sales_invoices where id=target_invoice;
  if target_company is null or not public.has_company_permission(target_company,'sales') then raise exception 'Sales access denied'; end if;
  if not exists(select 1 from public.contacts where id=(header->>'customer_id')::uuid and company_id=target_company and kind in ('customer','both'))
    or not exists(select 1 from public.branches where id=(header->>'branch_id')::uuid and company_id=target_company) then raise exception 'Customer or branch belongs to another company'; end if;
  if jsonb_typeof(items) is distinct from 'array' or jsonb_array_length(items)=0 then raise exception 'Invoice lines are required'; end if;
  if should_post is null then raise exception 'Posting choice is required'; end if;
  if (header->>'invoice_date')::date is null or (header->>'due_date')::date is null then raise exception 'Invoice dates are required'; end if;
  if exists(select 1 from jsonb_array_elements(items) x where
    nullif(trim(x->>'description'),'') is null
    or (x->>'quantity')::numeric is null or (x->>'quantity')::numeric<=0
    or (x->>'quantity')::numeric::text in ('NaN','Infinity','-Infinity')
    or (x->>'unit_price')::numeric is null or (x->>'unit_price')::numeric<0
    or (x->>'unit_price')::numeric::text in ('NaN','Infinity','-Infinity')
    or (x->>'gst_rate')::numeric is null or (x->>'gst_rate')::numeric not between 0 and 100
    or (x->>'gst_rate')::numeric::text in ('NaN','Infinity','-Infinity')
    or (nullif(x->>'product_id','') is not null and not exists(select 1 from public.products p
      where p.id=(x->>'product_id')::uuid and p.company_id=target_company and p.active))
    or (nullif(x->>'sales_order_line_id','') is not null and not exists(select 1 from public.sales_invoice_lines l
      where l.invoice_id=target_invoice and l.sales_order_line_id=(x->>'sales_order_line_id')::uuid
        and l.product_id is not distinct from nullif(x->>'product_id','')::uuid))) then
    raise exception 'Invalid invoice line or item outside this company/original order';
  end if;
  draft_id:=public.correct_sales_invoice(target_invoice,'Invoice edited by user');
  update public.sales_invoices set customer_id=(header->>'customer_id')::uuid,branch_id=(header->>'branch_id')::uuid,
    invoice_date=(header->>'invoice_date')::date,due_date=(header->>'due_date')::date,
    reference=nullif(header->>'reference','') where id=draft_id;
  delete from public.sales_invoice_lines where invoice_id=draft_id;
  insert into public.sales_invoice_lines(invoice_id,sales_order_line_id,product_id,description,quantity,unit_price,gst_rate)
  select draft_id,nullif(x->>'sales_order_line_id','')::uuid,nullif(x->>'product_id','')::uuid,x->>'description',
    (x->>'quantity')::numeric,(x->>'unit_price')::numeric,(x->>'gst_rate')::numeric from jsonb_array_elements(items) x;
  if should_post then perform public.post_sales_invoice(draft_id); end if;
  return draft_id;
end; $$;
revoke all on function public.save_sales_invoice_correction(uuid,jsonb,jsonb,boolean) from public,anon;
grant execute on function public.save_sales_invoice_correction(uuid,jsonb,jsonb,boolean) to authenticated;
commit;
