begin;
alter table goods_handover_events add column request_id uuid unique;
create function public.get_goods_handover_progress(target_kind text,target_source uuid) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare cid uuid; lines jsonb; legacy boolean;
begin
 if target_kind='delivery' then select company_id into cid from sales_invoices where id=target_source;
 elsif target_kind='receipt' then select company_id into cid from purchase_bills where id=target_source;
 else raise exception 'Invalid document kind';end if;
 if cid is null or not has_company_permission(cid,case when target_kind='delivery' then 'sales' else 'purchases' end) then raise exception 'Access denied';end if;
 select exists(select 1 from goods_handover_events e where e.company_id=cid and e.kind=target_kind and e.source_id=target_source and e.event_type='confirmed' and not exists(select 1 from goods_handover_events c where c.cancels_id=e.id) and exists(select 1 from jsonb_array_elements(e.items) x where not x ? 'line_id')) into legacy;
 with originals as (
 select l.id,l.product_id,l.description,l.quantity,p.sku,p.unit from sales_invoice_lines l join products p on p.id=l.product_id and p.company_id=cid and not p.is_service where target_kind='delivery' and l.invoice_id=target_source
 union all select l.id,l.product_id,l.description,l.quantity,p.sku,p.unit from purchase_bill_lines l join products p on p.id=l.product_id and p.company_id=cid and not p.is_service where target_kind='receipt' and l.bill_id=target_source
 ), balances as (
 select o.*,coalesce((select sum((x->>'quantity')::numeric) from goods_handover_events e cross join lateral jsonb_array_elements(e.items) x where e.company_id=cid and e.kind=target_kind and e.source_id=target_source and e.event_type='confirmed' and not exists(select 1 from goods_handover_events c where c.cancels_id=e.id) and x->>'line_id'=o.id::text),0) as partial_confirmed,
 case when target_kind='delivery' then coalesce((select sum(l.quantity) from sales_credit_note_lines l join sales_credit_notes n on n.id=l.credit_note_id where l.invoice_line_id=o.id and n.status='posted'),0)
 else coalesce((select sum(l.quantity) from purchase_debit_note_lines l join purchase_debit_notes n on n.id=l.debit_note_id where l.bill_line_id=o.id and n.status='posted'),0) end as returned from originals o
 ) select jsonb_agg(jsonb_build_object('line_id',id,'product_id',product_id,'description',description,'sku',sku,'unit',unit,'quantity',quantity,'returned',returned,'confirmed',case when legacy then quantity else partial_confirmed end,'remaining',case when legacy then 0 else greatest(quantity-returned-partial_confirmed,0) end) order by id) into lines from balances;
 return jsonb_build_object('lines',coalesce(lines,'[]'::jsonb),'legacy_active',legacy);
end $$;
create function public.record_partial_goods_handover(target_kind text,target_source uuid,target_date date,recipient text,target_notes text,quantities jsonb,target_request uuid) returns uuid language plpgsql security definer set search_path=public as $$
declare cid uuid; source_date date; source_status text; result uuid; progress jsonb; item jsonb; source_line jsonb; quantity numeric; snapshot jsonb:='[]';
begin
 if target_kind='delivery' then select company_id,invoice_date,status::text into cid,source_date,source_status from sales_invoices where id=target_source for update;perform 1 from sales_invoice_lines where invoice_id=target_source order by id for update;
 elsif target_kind='receipt' then select company_id,bill_date,status::text into cid,source_date,source_status from purchase_bills where id=target_source for update;perform 1 from purchase_bill_lines where bill_id=target_source order by id for update;
 else raise exception 'Invalid document kind';end if;
 if cid is null or not has_company_permission(cid,case when target_kind='delivery' then 'sales' else 'purchases' end) then raise exception 'Access denied';end if;
 if target_request is null then raise exception 'Request identifier required';end if;
 select id into result from goods_handover_events where request_id=target_request and company_id=cid and kind=target_kind and source_id=target_source;
 if result is not null then return result;end if;
 if source_status not in ('posted','part_paid','paid') or target_date is null or target_date<source_date or target_date>(now() at time zone 'Asia/Karachi')::date or length(trim(coalesce(recipient,'')))<2 then raise exception 'Posted source, valid received date and recipient required';end if;
 if quantities is null or jsonb_typeof(quantities)<>'array' or jsonb_array_length(quantities)=0 then raise exception 'Select at least one received quantity';end if;
 if exists(select 1 from jsonb_array_elements(quantities) x group by x->>'line_id' having count(*)>1) then raise exception 'Duplicate goods line';end if;
 progress:=get_goods_handover_progress(target_kind,target_source);
 if (progress->>'legacy_active')::boolean then raise exception 'Cancel the existing full confirmation before recording partial quantities';end if;
 for item in select value from jsonb_array_elements(quantities) loop
 select value into source_line from jsonb_array_elements(progress->'lines') where value->>'line_id'=item->>'line_id';
 quantity:=(item->>'quantity')::numeric;
 if source_line is null or quantity is null or quantity::text in ('NaN','Infinity','-Infinity') or quantity<=0 or quantity<>round(quantity,3) or quantity>(source_line->>'remaining')::numeric then raise exception 'Invalid quantity or quantity exceeds remaining goods';end if;
 snapshot:=snapshot||jsonb_build_array((source_line-'returned'-'confirmed'-'remaining')||jsonb_build_object('quantity',quantity));
 end loop;
 insert into goods_handover_events(company_id,kind,source_id,event_type,event_date,received_by,notes,items,request_id) values(cid,target_kind,target_source,'confirmed',target_date,trim(recipient),nullif(trim(target_notes),''),snapshot,target_request) returning id into result;
 return result;
end $$;
revoke all on function get_goods_handover_progress(text,uuid),record_partial_goods_handover(text,uuid,date,text,text,jsonb,uuid) from public,anon;
grant execute on function get_goods_handover_progress(text,uuid),record_partial_goods_handover(text,uuid,date,text,text,jsonb,uuid) to authenticated;
create or replace function public.record_goods_handover(target_kind text,target_source uuid,target_date date,recipient text,target_notes text default null,cancel_event uuid default null) returns uuid language plpgsql security definer set search_path=public as $$
declare cid uuid; source_date date; source_status text; snapshot jsonb; active_id uuid; result uuid; prior goods_handover_events%rowtype;
begin
 if target_kind='delivery' then
  select company_id,invoice_date,status::text into cid,source_date,source_status from sales_invoices where id=target_source for update;
 elsif target_kind='receipt' then
  select company_id,bill_date,status::text into cid,source_date,source_status from purchase_bills where id=target_source for update;
 else raise exception 'Invalid goods document kind'; end if;
 if cid is null or not has_company_permission(cid,case when target_kind='delivery' then 'sales' else 'purchases' end) then raise exception 'Goods document not found or access denied'; end if;
 if target_date is null or target_date>(now() at time zone 'Asia/Karachi')::date then raise exception 'Confirmation date cannot be in the future'; end if;
 if cancel_event is not null then
  select * into prior from goods_handover_events where id=cancel_event and company_id=cid and kind=target_kind and source_id=target_source and event_type='confirmed';
  if not found then raise exception 'Confirmation not found'; end if;
  select id into result from goods_handover_events where cancels_id=prior.id;
  if result is not null then return result; end if;
  if target_date<prior.event_date or length(trim(coalesce(target_notes,'')))<3 then raise exception 'Cancellation requires a reason and date on or after confirmation'; end if;
  insert into goods_handover_events(company_id,kind,source_id,event_type,event_date,received_by,notes,items,cancels_id) values(cid,target_kind,target_source,'cancelled',target_date,prior.received_by,trim(target_notes),prior.items,prior.id) returning id into result;
  return result;
 end if;
 if source_status not in ('posted','part_paid','paid') then raise exception 'Only posted goods documents can be confirmed'; end if;
 if target_date<source_date or length(trim(coalesce(recipient,'')))<2 then raise exception 'Recipient and date on or after document date required'; end if;
 select e.id into active_id from goods_handover_events e where e.company_id=cid and e.kind=target_kind and e.source_id=target_source and e.event_type='confirmed' and not exists(select 1 from goods_handover_events c where c.cancels_id=e.id);
 if active_id is not null then return active_id; end if;
 if target_kind='delivery' then
  perform 1 from sales_invoice_lines where invoice_id=target_source for update;
  if exists(select 1 from sales_credit_notes where invoice_id=target_source and status='posted') then raise exception 'Returned invoice requires partial handover review; full confirmation is unavailable'; end if;
  select jsonb_agg(jsonb_build_object('product_id',p.id,'sku',p.sku,'unit',p.unit,'description',l.description,'quantity',l.quantity) order by l.id) into snapshot from sales_invoice_lines l join products p on p.id=l.product_id and p.company_id=cid and not p.is_service where l.invoice_id=target_source;
 else
  perform 1 from purchase_bill_lines where bill_id=target_source for update;
  if exists(select 1 from purchase_debit_notes where bill_id=target_source and status='posted') then raise exception 'Returned bill requires partial receipt review; full confirmation is unavailable'; end if;
  select jsonb_agg(jsonb_build_object('product_id',p.id,'sku',p.sku,'unit',p.unit,'description',l.description,'quantity',l.quantity) order by l.id) into snapshot from purchase_bill_lines l join products p on p.id=l.product_id and p.company_id=cid and not p.is_service where l.bill_id=target_source;
 end if;
 if snapshot is null then raise exception 'No stock product lines to confirm'; end if;
 insert into goods_handover_events(company_id,kind,source_id,event_type,event_date,received_by,notes,items) values(cid,target_kind,target_source,'confirmed',target_date,trim(recipient),nullif(trim(target_notes),''),snapshot) returning id into result;
 return result;
end $$;
commit;
