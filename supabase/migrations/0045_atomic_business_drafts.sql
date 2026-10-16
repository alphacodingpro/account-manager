begin;
create function public.save_sales_invoice_draft(target_invoice uuid,header jsonb,items jsonb,should_post boolean default false) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare result uuid; cid uuid; source sales_invoices%rowtype; item jsonb; qty numeric; price numeric; tax numeric;
begin
 if auth.uid() is null or should_post is null then raise exception 'Authenticated session and posting choice required';end if;
 if target_invoice is null then cid:=(header->>'company_id')::uuid;
 else
  select * into source from sales_invoices where id=target_invoice for update;
  if not found or source.status<>'draft' then raise exception 'Draft invoice not found; posted invoices require correction';end if;
  cid:=source.company_id;
 end if;
 if cid is null or not has_company_permission(cid,'sales') or (header->>'company_id')::uuid is distinct from cid then raise exception 'Sales access denied';end if;
 if not exists(select 1 from contacts where id=(header->>'customer_id')::uuid and company_id=cid and active and kind in ('customer','both')) or not exists(select 1 from branches where id=(header->>'branch_id')::uuid and company_id=cid and active) then raise exception 'Active company customer and branch required';end if;
 if (header->>'invoice_date')::date is null or (header->>'due_date')::date is null or (header->>'due_date')::date<(header->>'invoice_date')::date then raise exception 'Valid invoice date and due date on or after invoice date required';end if;
 if items is null or jsonb_typeof(items)<>'array' or jsonb_array_length(items)=0 then raise exception 'Invoice lines required';end if;
 for item in select value from jsonb_array_elements(items) loop
  qty:=(item->>'quantity')::numeric;price:=(item->>'unit_price')::numeric;tax:=(item->>'gst_rate')::numeric;
  if nullif(trim(item->>'description'),'') is null or qty is null or price is null or tax is null or qty::text in ('NaN','Infinity','-Infinity') or price::text in ('NaN','Infinity','-Infinity') or tax::text in ('NaN','Infinity','-Infinity') or qty<=0 or qty>=1000000000000000 or qty<>round(qty,3) or price<0 or price>=10000000000000000 or price<>round(price,2) or tax<0 or tax>100 or tax<>round(tax,2) then raise exception 'Invalid invoice line, price, quantity or GST';end if;
  if nullif(item->>'product_id','') is not null and not exists(select 1 from products where id=(item->>'product_id')::uuid and company_id=cid and active) then raise exception 'Invalid company product';end if;
  if nullif(item->>'sales_order_line_id','') is not null and not exists(select 1 from sales_invoice_lines where invoice_id=target_invoice and sales_order_line_id=(item->>'sales_order_line_id')::uuid and product_id is not distinct from nullif(item->>'product_id','')::uuid) then raise exception 'Order line is not part of the original invoice';end if;
 end loop;
 if target_invoice is null then
  insert into sales_invoices(company_id,branch_id,customer_id,invoice_date,due_date,reference,created_by) values(cid,(header->>'branch_id')::uuid,(header->>'customer_id')::uuid,(header->>'invoice_date')::date,(header->>'due_date')::date,nullif(header->>'reference',''),auth.uid()) returning id into result;
 else
  result:=source.id;
  update sales_invoices set branch_id=(header->>'branch_id')::uuid,customer_id=(header->>'customer_id')::uuid,invoice_date=(header->>'invoice_date')::date,due_date=(header->>'due_date')::date,reference=nullif(header->>'reference','') where id=result;
  delete from sales_invoice_lines where invoice_id=result;
 end if;
 insert into sales_invoice_lines(invoice_id,sales_order_line_id,product_id,description,quantity,unit_price,gst_rate)
 select result,nullif(x->>'sales_order_line_id','')::uuid,nullif(x->>'product_id','')::uuid,x->>'description',(x->>'quantity')::numeric,(x->>'unit_price')::numeric,(x->>'gst_rate')::numeric from jsonb_array_elements(items) x;
 if should_post then perform post_sales_invoice(result);end if;
 return result;
end $$;
revoke all on function save_sales_invoice_draft(uuid,jsonb,jsonb,boolean) from public,anon;
grant execute on function save_sales_invoice_draft(uuid,jsonb,jsonb,boolean) to authenticated;
create function public.save_purchase_bill_draft(target_bill uuid,header jsonb,items jsonb,should_post boolean default false) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare result uuid; cid uuid; source purchase_bills%rowtype; item jsonb; qty numeric; price numeric; tax numeric;
begin
 if auth.uid() is null or should_post is null then raise exception 'Authenticated session and posting choice required';end if;
 if target_bill is null then cid:=(header->>'company_id')::uuid;
 else
  select * into source from purchase_bills where id=target_bill for update;
  if not found or source.status<>'draft' then raise exception 'Draft bill not found; posted bills require source reversal';end if;
  cid:=source.company_id;
 end if;
 if cid is null or not has_company_permission(cid,'purchases') or (header->>'company_id')::uuid is distinct from cid then raise exception 'Purchase access denied';end if;
 if not exists(select 1 from contacts where id=(header->>'supplier_id')::uuid and company_id=cid and active and kind in ('supplier','both')) or not exists(select 1 from branches where id=(header->>'branch_id')::uuid and company_id=cid and active) then raise exception 'Active company supplier and branch required';end if;
 if (header->>'bill_date')::date is null or (header->>'due_date')::date is null or (header->>'due_date')::date<(header->>'bill_date')::date then raise exception 'Valid bill date and due date on or after bill date required';end if;
 if nullif(header->>'warehouse_id','') is not null and not exists(select 1 from warehouses where id=(header->>'warehouse_id')::uuid and company_id=cid and branch_id=(header->>'branch_id')::uuid and active) then raise exception 'Invalid company warehouse';end if;
 if items is null or jsonb_typeof(items)<>'array' or jsonb_array_length(items)=0 then raise exception 'Bill lines required';end if;
 for item in select value from jsonb_array_elements(items) loop
  qty:=(item->>'quantity')::numeric;price:=(item->>'unit_price')::numeric;tax:=(item->>'gst_rate')::numeric;
  if nullif(trim(item->>'description'),'') is null or qty is null or price is null or tax is null or qty::text in ('NaN','Infinity','-Infinity') or price::text in ('NaN','Infinity','-Infinity') or tax::text in ('NaN','Infinity','-Infinity') or qty<=0 or qty>=1000000000000000 or qty<>round(qty,3) or price<0 or price>=10000000000000000 or price<>round(price,2) or tax<0 or tax>100 or tax<>round(tax,2) then raise exception 'Invalid bill line, price, quantity or GST';end if;
  if nullif(item->>'product_id','') is not null and not exists(select 1 from products where id=(item->>'product_id')::uuid and company_id=cid and active) then raise exception 'Invalid company product';end if;
  if nullif(item->>'expense_account_id','') is not null and not exists(select 1 from accounts where id=(item->>'expense_account_id')::uuid and company_id=cid and active and type='expense') then raise exception 'Invalid expense account';end if;
  if (nullif(item->>'product_id','') is null or exists(select 1 from products where id=(item->>'product_id')::uuid and is_service)) and nullif(item->>'expense_account_id','') is null then raise exception 'Expense account required for non-stock lines';end if;
  if exists(select 1 from products where id=nullif(item->>'product_id','')::uuid and not is_service) and (nullif(header->>'warehouse_id','') is null or nullif(item->>'expense_account_id','') is not null) then raise exception 'Stock lines require a warehouse and the inventory account';end if;
  if nullif(item->>'purchase_order_line_id','') is not null and not exists(select 1 from purchase_bill_lines where bill_id=target_bill and purchase_order_line_id=(item->>'purchase_order_line_id')::uuid and product_id is not distinct from nullif(item->>'product_id','')::uuid) then raise exception 'Order line is not part of the original bill';end if;
 end loop;
 if target_bill is null then
  insert into purchase_bills(company_id,branch_id,warehouse_id,supplier_id,bill_date,due_date,supplier_reference,notes,created_by) values(cid,(header->>'branch_id')::uuid,nullif(header->>'warehouse_id','')::uuid,(header->>'supplier_id')::uuid,(header->>'bill_date')::date,(header->>'due_date')::date,nullif(header->>'supplier_reference',''),header->>'notes',auth.uid()) returning id into result;
 else
  result:=source.id;
  update purchase_bills set warehouse_id=nullif(header->>'warehouse_id','')::uuid,notes=header->>'notes',branch_id=(header->>'branch_id')::uuid,supplier_id=(header->>'supplier_id')::uuid,bill_date=(header->>'bill_date')::date,due_date=(header->>'due_date')::date,supplier_reference=nullif(header->>'supplier_reference','') where id=result;
  delete from purchase_bill_lines where bill_id=result;
 end if;
 insert into purchase_bill_lines(bill_id,purchase_order_line_id,product_id,expense_account_id,description,quantity,unit_price,gst_rate)
 select result,nullif(x->>'purchase_order_line_id','')::uuid,nullif(x->>'product_id','')::uuid,nullif(x->>'expense_account_id','')::uuid,x->>'description',(x->>'quantity')::numeric,(x->>'unit_price')::numeric,(x->>'gst_rate')::numeric from jsonb_array_elements(items) x;
 if should_post then perform post_purchase_bill(result);end if;
 return result;
end $$;
revoke all on function save_purchase_bill_draft(uuid,jsonb,jsonb,boolean) from public,anon;
grant execute on function save_purchase_bill_draft(uuid,jsonb,jsonb,boolean) to authenticated;
commit;
