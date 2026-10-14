begin;
create table public.goods_handover_events(
 id uuid primary key default gen_random_uuid(),company_id uuid not null references companies(id),kind text not null check(kind in ('delivery','receipt')),source_id uuid not null,event_type text not null check(event_type in ('confirmed','cancelled')),event_date date not null,received_by text not null,notes text,items jsonb not null,cancels_id uuid unique references goods_handover_events(id),created_by uuid not null default auth.uid() references auth.users(id),created_at timestamptz not null default now(),check((event_type='cancelled')=(cancels_id is not null))
);
create index goods_handover_source on goods_handover_events(company_id,kind,source_id,created_at);
alter table goods_handover_events enable row level security;
create policy "goods handover read" on goods_handover_events for select to authenticated using(has_company_permission(company_id,case when kind='delivery' then 'sales' else 'purchases' end));
-- Append-only evidence: clients cannot insert/update/delete events directly.
create trigger goods_handover_audit after insert on goods_handover_events for each row execute function write_audit_log();
create function public.record_goods_handover(target_kind text,target_source uuid,target_date date,recipient text,target_notes text default null,cancel_event uuid default null) returns uuid language plpgsql security definer set search_path=public as $$
declare cid uuid; source_date date; source_status text; snapshot jsonb; active_id uuid; result uuid; prior goods_handover_events%rowtype;
begin
 if target_kind='delivery' then
  select company_id,invoice_date,status::text into cid,source_date,source_status from sales_invoices where id=target_source for update;
 elsif target_kind='receipt' then
  select company_id,bill_date,status::text into cid,source_date,source_status from purchase_bills where id=target_source for update;
 else raise exception 'Invalid goods document kind'; end if;
 if cid is null or not has_company_permission(cid,case when target_kind='delivery' then 'sales' else 'purchases' end) then raise exception 'Goods document not found or access denied'; end if;
 if target_date is null or target_date>current_date then raise exception 'Confirmation date cannot be in the future'; end if;
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
revoke all on function record_goods_handover(text,uuid,date,text,text,uuid) from public,anon;
grant execute on function record_goods_handover(text,uuid,date,text,text,uuid) to authenticated;
commit;
