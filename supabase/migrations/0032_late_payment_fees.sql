-- Late fees are separate invoices, eligible for normal receipt allocation and voiding.
create function public.create_late_payment_fee(target_invoice uuid, fee_amount numeric, fee_gst_rate numeric, charge_date date, should_post boolean default false)
returns uuid language plpgsql security invoker set search_path=public as $$
declare source sales_invoices%rowtype; result uuid; marker text;
begin
 select * into source from sales_invoices where id=target_invoice for update;
 if not found or not public.has_company_permission(source.company_id,'sales') then raise exception 'Invoice not found or access denied'; end if;
 if source.status not in ('posted','paid') or source.total<=source.amount_paid then raise exception 'Invoice has no outstanding balance'; end if;
 if source.reference like 'LATE-FEE:%' then raise exception 'Fees cannot be charged on fee invoices'; end if;
 if charge_date is null or charge_date<=source.due_date or charge_date<source.invoice_date then raise exception 'Charge date must be after invoice due date'; end if;
 if fee_amount is null or fee_amount::text in ('NaN','Infinity','-Infinity') or fee_amount<=0 or fee_amount<>round(fee_amount,2) or fee_amount>=10000000000000000 then raise exception 'Invalid fee amount'; end if;
 if fee_gst_rate is null or fee_gst_rate::text in ('NaN','Infinity','-Infinity') or fee_gst_rate<0 or fee_gst_rate>100 or fee_gst_rate<>round(fee_gst_rate,2) then raise exception 'Invalid GST rate'; end if;
 marker:='LATE-FEE:'||source.id||':'||charge_date;
 if exists(select 1 from sales_invoices where company_id=source.company_id and reference=marker and status<>'void') then raise exception 'A fee for this invoice and date already exists'; end if;
 insert into sales_invoices(company_id,branch_id,customer_id,invoice_date,due_date,reference,notes,created_by) values(source.company_id,source.branch_id,source.customer_id,charge_date,charge_date,marker,'Late payment fee for INV-'||source.invoice_number,auth.uid()) returning id into result;
 insert into sales_invoice_lines(invoice_id,description,quantity,unit_price,gst_rate) values(result,'Late payment fee for INV-'||source.invoice_number||' (due '||source.due_date||')',1,fee_amount,fee_gst_rate);
 if should_post then perform public.post_sales_invoice(result); end if;
 return result;
end $$;
revoke all on function public.create_late_payment_fee(uuid,numeric,numeric,date,boolean) from public,anon;
grant execute on function public.create_late_payment_fee(uuid,numeric,numeric,date,boolean) to authenticated;
