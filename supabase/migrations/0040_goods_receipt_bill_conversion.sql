begin;
-- One receipt draft can create one reviewable bill; no stock moves at conversion.
create table public.goods_receipt_bill_links (
 receipt_id uuid primary key references goods_document_drafts(id) on delete restrict,
 bill_id uuid not null unique references purchase_bills(id) on delete cascade,
 company_id uuid not null references companies(id),
 created_by uuid not null default auth.uid() references auth.users(id),
 created_at timestamptz not null default now()
);
alter table goods_receipt_bill_links enable row level security;
create policy "receipt bill link read" on goods_receipt_bill_links for select to authenticated using(has_company_permission(company_id,'purchases'));
-- Link writes are exclusively through the validated conversion RPC.
create function public.lock_converted_goods_receipt() returns trigger language plpgsql security invoker set search_path=public as $$
begin
 if exists(select 1 from goods_receipt_bill_links where receipt_id=old.id) then raise exception 'Converted receipt is read-only; review the linked bill'; end if;
 return coalesce(new,old);
end $$;
create trigger converted_goods_receipt_lock before update or delete on goods_document_drafts for each row execute function lock_converted_goods_receipt();
create trigger receipt_bill_link_audit after insert or delete on goods_receipt_bill_links for each row execute function write_audit_log();
create function public.convert_goods_receipt_to_bill(target_receipt uuid,target_due_date date,prices jsonb) returns uuid language plpgsql security definer set search_path=public as $$
declare receipt goods_document_drafts%rowtype; result uuid; branch uuid; item jsonb; price jsonb; amount numeric; tax numeric;
begin
 select * into receipt from goods_document_drafts where id=target_receipt for update;
 if not found or receipt.kind<>'receipt' or not has_company_permission(receipt.company_id,'purchases') then raise exception 'Receipt not found or purchase access denied'; end if;
 select bill_id into result from goods_receipt_bill_links where receipt_id=receipt.id;
 if result is not null then return result; end if;
 if target_due_date is null or target_due_date<receipt.document_date then raise exception 'Due date must be on or after receipt date'; end if;
 select w.branch_id into branch from warehouses w join branches b on b.id=w.branch_id and b.company_id=w.company_id and b.active where w.id=receipt.warehouse_id and w.company_id=receipt.company_id and w.active;
 if branch is null then raise exception 'Active company warehouse and branch required'; end if;
 if not exists(select 1 from contacts where id=receipt.contact_id and company_id=receipt.company_id and active and kind in ('supplier','both')) then raise exception 'Active supplier required'; end if;
 if prices is null or jsonb_typeof(prices)<>'array' or jsonb_array_length(prices)<>jsonb_array_length(receipt.items) then raise exception 'Review price and GST for every goods line'; end if;
 if exists(select 1 from jsonb_array_elements(prices) p group by p->>'product_id' having count(*)>1) then raise exception 'Duplicate price line'; end if;
 insert into purchase_bills(company_id,branch_id,warehouse_id,supplier_id,supplier_reference,bill_date,due_date,notes,created_by)
 values(receipt.company_id,branch,receipt.warehouse_id,receipt.contact_id,receipt.reference,receipt.document_date,target_due_date,concat('Goods receipt draft GR-',receipt.document_number,E'\n',receipt.notes),auth.uid()) returning id into result;
 for item in select value from jsonb_array_elements(receipt.items) loop
  if not exists(select 1 from products where id=(item->>'product_id')::uuid and company_id=receipt.company_id and active and not is_service) then raise exception 'Invalid stock product'; end if;
  select value into price from jsonb_array_elements(prices) where value->>'product_id'=item->>'product_id';
  amount:=(price->>'unit_price')::numeric;tax:=(price->>'gst_rate')::numeric;
  if amount is null or tax is null or amount::text in ('NaN','Infinity','-Infinity') or tax::text in ('NaN','Infinity','-Infinity') or amount<0 or amount>=10000000000000000 or amount<>round(amount,2) or tax<0 or tax>100 or tax<>round(tax,2) then raise exception 'Invalid price or GST'; end if;
  insert into purchase_bill_lines(bill_id,product_id,description,quantity,unit_price,gst_rate) values(result,(item->>'product_id')::uuid,item->>'description',(item->>'quantity')::numeric,amount,tax);
 end loop;
 insert into goods_receipt_bill_links(receipt_id,bill_id,company_id) values(receipt.id,result,receipt.company_id);
 return result;
end $$;
revoke all on function convert_goods_receipt_to_bill(uuid,date,jsonb) from public,anon;
grant execute on function convert_goods_receipt_to_bill(uuid,date,jsonb) to authenticated;
commit;
