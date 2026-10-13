begin;
create or replace function public.validate_purchase_quote() returns trigger language plpgsql security invoker set search_path=public as $$
declare item jsonb; qty numeric; price numeric; rate numeric;
begin
 if tg_op='DELETE' then if old.status<>'draft' then raise exception 'Only quote drafts may be deleted';end if;return old;end if;
 if tg_op='INSERT' and (new.status<>'draft' or new.converted_order_id is not null) then raise exception 'Create a draft first';end if;
 if tg_op='UPDATE' then
  if new.company_id<>old.company_id or new.created_by<>old.created_by then raise exception 'Quote ownership immutable';end if;
  if old.status<>'draft' and (to_jsonb(new)-'status'-'converted_order_id')<>(to_jsonb(old)-'status'-'converted_order_id') then raise exception 'Approved quotes are immutable';end if;
  if old.status='converted' or (old.status='approved' and new.status<>'converted') or (old.status='draft' and new.status not in ('draft','approved')) then raise exception 'Invalid quote transition';end if;
 end if;
 if not exists(select 1 from contacts where id=new.supplier_id and company_id=new.company_id and active and kind in ('supplier','both')) or not exists(select 1 from branches where id=new.branch_id and company_id=new.company_id and active) then raise exception 'Invalid supplier or branch';end if;
 if new.status<>'converted' and new.converted_order_id is not null then raise exception 'Unexpected order link';end if;
 if new.status='converted' and not exists(select 1 from purchase_orders where id=new.converted_order_id and company_id=new.company_id and supplier_id=new.supplier_id) then raise exception 'Invalid converted order';end if;
 for item in select value from jsonb_array_elements(new.items) loop
  qty:=(item->>'quantity')::numeric;price:=(item->>'unit_price')::numeric;rate:=(item->>'gst_rate')::numeric;
  if qty is null or price is null or rate is null or qty::text in ('NaN','Infinity','-Infinity') or price::text in ('NaN','Infinity','-Infinity') or rate::text in ('NaN','Infinity','-Infinity') or qty<=0 or qty<>round(qty,3) or price<0 or price<>round(price,2) or rate<0 or rate>100 or rate<>round(rate,2) or nullif(trim(item->>'description'),'') is null then raise exception 'Invalid quote line';end if;
  if nullif(item->>'product_id','') is not null and not exists(select 1 from products where id=(item->>'product_id')::uuid and company_id=new.company_id and active) then raise exception 'Invalid quote product';end if;
  if nullif(item->>'expense_account_id','') is not null and not exists(select 1 from accounts where id=(item->>'expense_account_id')::uuid and company_id=new.company_id and active and type='expense') then raise exception 'Invalid quote expense account';end if;
  if (nullif(item->>'product_id','') is null or exists(select 1 from products where id=(item->>'product_id')::uuid and is_service)) and nullif(item->>'expense_account_id','') is null then raise exception 'Service and expense lines require an expense account';end if;
 end loop;
 return new;
end $$;
create or replace function public.convert_purchase_quote(target_quote uuid) returns uuid language plpgsql security invoker set search_path=public as $$
declare q purchase_quotes%rowtype; result uuid; item jsonb; destination uuid;
begin
 select * into q from purchase_quotes where id=target_quote for update;
 if not found or not has_company_permission(q.company_id,'purchases') or q.status<>'approved' then raise exception 'Approved quote not found or access denied';end if;
 if q.valid_until<current_date then raise exception 'Quote expired';end if;
 select id into destination from warehouses where company_id=q.company_id and branch_id=q.branch_id and active order by created_at,id limit 1;
 if destination is null and exists(select 1 from jsonb_array_elements(q.items) i join products p on p.id=nullif(i->>'product_id','')::uuid where not p.is_service) then raise exception 'Active branch warehouse required';end if;
 insert into purchase_orders(company_id,branch_id,warehouse_id,supplier_id,order_date,supplier_reference,notes,created_by) values(q.company_id,q.branch_id,destination,q.supplier_id,current_date,'PQ-'||q.quote_number,q.notes,auth.uid()) returning id into result;
 for item in select value from jsonb_array_elements(q.items) loop
  insert into purchase_order_lines(purchase_order_id,product_id,expense_account_id,description,quantity,unit_price,gst_rate) values(result,nullif(item->>'product_id','')::uuid,nullif(item->>'expense_account_id','')::uuid,item->>'description',(item->>'quantity')::numeric,(item->>'unit_price')::numeric,(item->>'gst_rate')::numeric);
 end loop;
 update purchase_quotes set status='converted',converted_order_id=result where id=q.id;
 return result;
end $$;
commit;
