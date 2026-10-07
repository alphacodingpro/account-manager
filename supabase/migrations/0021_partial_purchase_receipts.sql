-- Allow one approved purchase order to be received into multiple bill drafts.
-- Receipt allocation is non-posting: stock, GST and AP still change only when
-- the resulting purchase bill is posted through post_purchase_bill.
begin;

drop index if exists public.purchase_bills_one_per_order;
alter table public.purchase_bill_lines
  add column if not exists purchase_order_line_id uuid references public.purchase_order_lines(id) on delete restrict;
create index if not exists purchase_bill_lines_order_line_idx
  on public.purchase_bill_lines(purchase_order_line_id) where purchase_order_line_id is not null;

create or replace function public.validate_purchase_order_bill_header()
returns trigger language plpgsql set search_path=public as $$
declare o public.purchase_orders%rowtype;
begin
  if new.purchase_order_id is null then return new; end if;
  select * into o from public.purchase_orders where id=new.purchase_order_id;
  if o.id is null or new.company_id<>o.company_id or new.branch_id<>o.branch_id
    or new.supplier_id<>o.supplier_id or new.warehouse_id is distinct from o.warehouse_id then
    raise exception 'Purchase-order bill company, branch, warehouse and supplier must match the order';
  end if;
  return new;
end; $$;
drop trigger if exists purchase_order_bill_header_valid on public.purchase_bills;
create trigger purchase_order_bill_header_valid before insert or update on public.purchase_bills
for each row execute function public.validate_purchase_order_bill_header();

create or replace function public.validate_purchase_order_bill_line()
returns trigger language plpgsql set search_path=public as $$
declare source public.purchase_order_lines%rowtype; bill public.purchase_bills%rowtype; allocated numeric(18,3); exclude_line uuid;
begin
  select * into bill from public.purchase_bills where id=new.bill_id;
  if bill.purchase_order_id is null then
    if new.purchase_order_line_id is not null then raise exception 'Source order line requires a purchase-order bill'; end if;
    return new;
  end if;
  if new.purchase_order_line_id is null then raise exception 'Every purchase-order bill line must reference its source order line'; end if;
  select * into source from public.purchase_order_lines where id=new.purchase_order_line_id and purchase_order_id=bill.purchase_order_id;
  if source.id is null or new.product_id is distinct from source.product_id
    or new.expense_account_id is distinct from source.expense_account_id then
    raise exception 'Bill line does not match its purchase-order source';
  end if;
  if tg_op='UPDATE' then exclude_line:=old.id; end if;
  select coalesce(sum(bl.quantity),0) into allocated
  from public.purchase_bill_lines bl join public.purchase_bills b on b.id=bl.bill_id
  where bl.purchase_order_line_id=source.id and b.status<>'void'
    and (exclude_line is null or bl.id<>exclude_line);
  if allocated+new.quantity>source.quantity then raise exception 'Received quantity exceeds the purchase-order balance'; end if;
  return new;
end; $$;
drop trigger if exists purchase_order_bill_line_valid on public.purchase_bill_lines;
create trigger purchase_order_bill_line_valid before insert or update on public.purchase_bill_lines
for each row execute function public.validate_purchase_order_bill_line();

create or replace view public.purchase_order_line_progress
with (security_invoker=true) as
select o.company_id, l.purchase_order_id, l.id as line_id, l.product_id, l.expense_account_id,
  l.description, l.quantity as ordered_quantity, l.unit_price, l.gst_rate,
  coalesce(sum(case when b.status<>'void' then bl.quantity else 0 end),0)::numeric(18,3) as received_quantity,
  (l.quantity-coalesce(sum(case when b.status<>'void' then bl.quantity else 0 end),0))::numeric(18,3) as remaining_quantity
from public.purchase_order_lines l
join public.purchase_orders o on o.id=l.purchase_order_id
left join public.purchase_bill_lines bl on bl.purchase_order_line_id=l.id
left join public.purchase_bills b on b.id=bl.bill_id
group by o.company_id,l.purchase_order_id,l.id,l.product_id,l.expense_account_id,l.description,l.quantity,l.unit_price,l.gst_rate;
revoke all on public.purchase_order_line_progress from public,anon;
grant select on public.purchase_order_line_progress to authenticated;

create or replace function public.create_partial_purchase_bill(target_order uuid,target_due_date date,receipt_lines jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare o public.purchase_orders%rowtype; new_bill uuid; requested_count integer; valid_count integer;
begin
  select * into o from public.purchase_orders where id=target_order and status='approved' for update;
  if o.id is null or not public.has_company_permission(o.company_id,'purchases') then raise exception 'Approved purchase order not found or purchase access denied'; end if;
  if o.converted_bill_id is not null then raise exception 'This legacy purchase order was already fully converted'; end if;
  if target_due_date is null or target_due_date<current_date then raise exception 'Bill due date cannot be in the past'; end if;
  if jsonb_typeof(receipt_lines)<>'array' or jsonb_array_length(receipt_lines)=0 then raise exception 'Select at least one quantity to receive'; end if;
  if exists(select 1 from jsonb_array_elements(receipt_lines) x group by x->>'line_id' having count(*)>1) then raise exception 'A purchase-order line cannot be submitted twice'; end if;
  perform 1 from public.purchase_order_lines where purchase_order_id=o.id for update;
  requested_count:=jsonb_array_length(receipt_lines);
  select count(*) into valid_count
  from jsonb_array_elements(receipt_lines) x
  join public.purchase_order_line_progress p on p.line_id=(x->>'line_id')::uuid and p.purchase_order_id=o.id
  where (x->>'quantity')::numeric>0 and (x->>'quantity')::numeric<=p.remaining_quantity;
  if valid_count<>requested_count then raise exception 'Receipt contains an invalid line or quantity above the remaining balance'; end if;

  insert into public.purchase_bills(company_id,branch_id,warehouse_id,supplier_id,supplier_reference,bill_date,due_date,notes,purchase_order_id,created_by)
  values(o.company_id,o.branch_id,o.warehouse_id,o.supplier_id,o.supplier_reference,current_date,target_due_date,
    concat('Partial receipt from PO-',lpad(o.order_number::text,6,'0'),case when o.notes is null then '' else ': '||o.notes end),o.id,auth.uid())
  returning id into new_bill;
  insert into public.purchase_bill_lines(bill_id,purchase_order_line_id,product_id,expense_account_id,description,quantity,unit_price,gst_rate)
  select new_bill,l.id,l.product_id,l.expense_account_id,l.description,(x->>'quantity')::numeric,l.unit_price,l.gst_rate
  from jsonb_array_elements(receipt_lines) x join public.purchase_order_lines l on l.id=(x->>'line_id')::uuid
  where l.purchase_order_id=o.id;
  return new_bill;
end; $$;

-- Keep old clients safe: the former full-receipt RPC now converts only the
-- quantities that remain instead of duplicating quantities already received.
create or replace function public.receive_purchase_order_to_bill(target_order uuid,target_due_date date)
returns uuid language plpgsql security definer set search_path=public as $$
declare payload jsonb;
begin
  select jsonb_agg(jsonb_build_object('line_id',line_id,'quantity',remaining_quantity)) into payload
  from public.purchase_order_line_progress where purchase_order_id=target_order and remaining_quantity>0;
  if payload is null then raise exception 'Purchase order has no remaining quantity'; end if;
  return public.create_partial_purchase_bill(target_order,target_due_date,payload);
end; $$;

revoke all on function public.create_partial_purchase_bill(uuid,date,jsonb) from public,anon;
grant execute on function public.create_partial_purchase_bill(uuid,date,jsonb) to authenticated;
commit;
