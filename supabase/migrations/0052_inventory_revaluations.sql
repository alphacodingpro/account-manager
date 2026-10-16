begin;
create table public.inventory_revaluations(
 id uuid primary key default gen_random_uuid(),sequence_number bigint generated always as identity,
 company_id uuid not null references companies(id),product_id uuid not null references products(id),
 request_id uuid not null unique,request_payload jsonb not null,
 quantity numeric(18,3) not null,old_average numeric(18,4) not null,new_average numeric(18,4) not null,
 old_value numeric(18,2) not null,new_value numeric(18,2) not null,value_change numeric(18,2) not null,
 offset_account_id uuid not null references accounts(id),reason text not null,movement_count bigint not null,
 allocations jsonb not null,status text not null default 'posted' check(status in ('posted','reversed')),
 reversal_entries jsonb,reversed_by uuid,reversed_at timestamptz,
 created_by uuid not null default auth.uid(),created_at timestamptz not null default now()
);
create index inventory_revaluation_product on inventory_revaluations(company_id,product_id,sequence_number);
alter table inventory_revaluations enable row level security;
create policy "inventory revaluation read" on inventory_revaluations for select to authenticated using(has_company_permission(company_id,'inventory') and has_company_permission(company_id,'accounting'));
create trigger inventory_revaluation_audit after insert or update on inventory_revaluations for each row execute function write_audit_log();

create function public.post_inventory_revaluation(target_company uuid,target_product uuid,target_average numeric,expected_average numeric,expected_quantity numeric,offset_account uuid,reason text,request_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp set timezone='Asia/Karachi' as $$
declare p products%rowtype; existing inventory_revaluations%rowtype; payload jsonb; result uuid; inventory uuid; old_value numeric; new_value numeric; delta numeric; previous_delta numeric:=0; cumulative_qty numeric:=0; allocation_delta numeric; stock_count bigint; row record; journal uuid; allocations jsonb:='[]';
begin
 if not has_company_permission(target_company,'inventory') or not has_company_permission(target_company,'accounting') then raise exception 'Inventory and accounting permission required';end if;
 if request_id is null or target_average is null or expected_average is null or expected_quantity is null or target_average::text in ('NaN','Infinity','-Infinity') or expected_average::text in ('NaN','Infinity','-Infinity') or expected_quantity::text in ('NaN','Infinity','-Infinity') or target_average<0 or target_average<>round(target_average,4) or target_average>=100000000000000 or length(trim(coalesce(reason,'')))<3 or length(reason)>1000 then raise exception 'Valid average cost, reviewed balance and reason required';end if;
 payload:=jsonb_build_object('product',target_product,'average',target_average,'expected_average',expected_average,'expected_quantity',expected_quantity,'offset',offset_account,'reason',trim(reason));
 select * into p from products where id=target_product and company_id=target_company and active and not is_service for update;
 if not found then raise exception 'Active company stock product required';end if;
 select * into existing from inventory_revaluations r where r.request_id=post_inventory_revaluation.request_id;
 if found then
  if existing.company_id<>target_company or existing.request_payload<>payload then raise exception 'Request identifier already used for different adjustment data';end if;return existing.id;
 end if;
 if p.quantity_on_hand<=0 then raise exception 'Positive stock quantity required for valuation adjustment';end if;
 if p.average_cost<>expected_average or p.quantity_on_hand<>expected_quantity then raise exception 'Stock balance changed; reload and review before posting';end if;
 if not exists(select 1 from accounts where id=offset_account and company_id=target_company and active and type='expense') then raise exception 'Active company adjustment expense account required';end if;
 select id into inventory from accounts where company_id=target_company and code='1200' and active and type='asset';
 if inventory is null then raise exception 'Active Inventory asset account 1200 required';end if;
 old_value:=round(p.quantity_on_hand*p.average_cost,2);new_value:=round(p.quantity_on_hand*target_average,2);delta:=new_value-old_value;
 if old_value>=10000000000000000 or new_value>=10000000000000000 then raise exception 'Stock value exceeds supported journal amount';end if;
 if delta=0 then raise exception 'No monetary stock value change at this quantity';end if;
 select count(*) into stock_count from stock_movements where company_id=target_company and product_id=p.id;
 for row in
  select m.warehouse_id,w.branch_id,w.active warehouse_active,b.active branch_active,w.company_id warehouse_company,b.company_id branch_company,
   sum(case when m.movement_type in ('opening','purchase','adjustment_in','transfer_in','return_in') then m.quantity else -m.quantity end) quantity
  from stock_movements m left join warehouses w on w.id=m.warehouse_id left join branches b on b.id=w.branch_id
  where m.company_id=target_company and m.product_id=p.id group by m.warehouse_id,w.branch_id,w.active,b.active,w.company_id,b.company_id order by m.warehouse_id
 loop
  if row.quantity<0 then raise exception 'Negative warehouse stock requires reconciliation';end if;
  if row.quantity=0 then continue;end if;
  if row.warehouse_company is distinct from target_company or row.branch_company is distinct from target_company or row.warehouse_active is distinct from true or row.branch_active is distinct from true then raise exception 'Stock warehouse and branch must be active in this company';end if;
  cumulative_qty:=cumulative_qty+row.quantity;
  allocation_delta:=round(cumulative_qty*target_average,2)-round(cumulative_qty*p.average_cost,2)-previous_delta;
  previous_delta:=previous_delta+allocation_delta;journal:=null;
  if allocation_delta<>0 then
   insert into journal_entries(company_id,branch_id,entry_date,reference,description,created_by) values(target_company,row.branch_id,(now() at time zone 'Asia/Karachi')::date,'Inventory valuation','Inventory valuation: '||trim(reason),auth.uid()) returning id into journal;
   insert into journal_lines(entry_id,account_id,description,debit,credit) values
    (journal,inventory,'Stock value adjustment',greatest(allocation_delta,0),greatest(-allocation_delta,0)),
    (journal,offset_account,'Valuation adjustment offset',greatest(-allocation_delta,0),greatest(allocation_delta,0));
   perform set_config('cloudledger.posting_permission','accounting',true);perform post_journal(journal);
  end if;
  allocations:=allocations||jsonb_build_array(jsonb_build_object('warehouse_id',row.warehouse_id,'branch_id',row.branch_id,'quantity',row.quantity,'value_change',allocation_delta,'journal_entry_id',journal));
 end loop;
 if cumulative_qty<>p.quantity_on_hand or previous_delta<>delta then raise exception 'Warehouse balances do not reconcile to product quantity';end if;
 perform set_config('cloudledger.allow_stock_quantity','on',true);update products set average_cost=target_average where id=p.id;perform set_config('cloudledger.allow_stock_quantity','',true);
 insert into inventory_revaluations(company_id,product_id,request_id,request_payload,quantity,old_average,new_average,old_value,new_value,value_change,offset_account_id,reason,movement_count,allocations)
 values(target_company,p.id,request_id,payload,p.quantity_on_hand,p.average_cost,target_average,old_value,new_value,delta,offset_account,trim(reason),stock_count,allocations) returning id into result;
 return result;
end $$;

create function public.reverse_inventory_revaluation(target_adjustment uuid,reason text) returns uuid language plpgsql security definer set search_path=public,pg_temp set timezone='Asia/Karachi' as $$
declare r inventory_revaluations%rowtype; p products%rowtype; item jsonb; result uuid; reversals jsonb:='[]'; stock_count bigint;
begin
 -- Product first matches posting/stock lock order and serializes competing adjustments.
 select * into r from inventory_revaluations where id=target_adjustment;
 if not found or not has_company_permission(r.company_id,'inventory') or not has_company_permission(r.company_id,'accounting') then raise exception 'Valuation adjustment not found or access denied';end if;
 select * into p from products where id=r.product_id and company_id=r.company_id for update;
 select * into r from inventory_revaluations where id=target_adjustment for update;
 if r.status='reversed' then return r.id;end if;
 if length(trim(coalesce(reason,'')))<3 then raise exception 'Reversal reason required';end if;
 select count(*) into stock_count from stock_movements where company_id=r.company_id and product_id=r.product_id;
 if stock_count<>r.movement_count or p.quantity_on_hand<>r.quantity or p.average_cost<>r.new_average or exists(select 1 from inventory_revaluations newer where newer.product_id=r.product_id and newer.company_id=r.company_id and newer.status='posted' and newer.sequence_number>r.sequence_number) then raise exception 'Later stock or valuation activity exists; use a new reviewed adjustment';end if;
 perform set_config('cloudledger.allow_stock_quantity','on',true);update products set average_cost=r.old_average where id=p.id;perform set_config('cloudledger.allow_stock_quantity','',true);
 perform set_config('cloudledger.revaluation_reversal_id',r.id::text,true);perform set_config('cloudledger.posting_permission','accounting',true);
 for item in select value from jsonb_array_elements(r.allocations) loop
  if item->>'journal_entry_id' is not null then
   result:=create_journal_reversal((item->>'journal_entry_id')::uuid,trim(reason));reversals:=reversals||jsonb_build_array(result);
  end if;
 end loop;
 perform set_config('cloudledger.revaluation_reversal_id','',true);
 update inventory_revaluations set status='reversed',reversal_entries=reversals,reversed_by=auth.uid(),reversed_at=now() where id=r.id;return r.id;
end $$;
create function public.guard_revaluation_journal_reversal() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if old.status='posted' and new.status='reversed' and exists(select 1 from inventory_revaluations r cross join lateral jsonb_array_elements(r.allocations) a where a->>'journal_entry_id'=old.id::text and coalesce(current_setting('cloudledger.revaluation_reversal_id',true),'')<>r.id::text) then raise exception 'Reverse this journal from its inventory valuation adjustment';end if;return new;
end $$;
create trigger revaluation_journal_reversal before update of status on journal_entries for each row execute function guard_revaluation_journal_reversal();
revoke all on function post_inventory_revaluation(uuid,uuid,numeric,numeric,numeric,uuid,text,uuid),reverse_inventory_revaluation(uuid,text) from public,anon;
grant execute on function post_inventory_revaluation(uuid,uuid,numeric,numeric,numeric,uuid,text,uuid),reverse_inventory_revaluation(uuid,text) to authenticated;

create or replace function public.reverse_goods_receipt(target_receipt uuid,reason text) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare r goods_document_drafts%rowtype; p goods_receipt_postings%rowtype; item jsonb; result uuid; movement_count bigint;
begin
 select * into r from goods_document_drafts where id=target_receipt for update;
 if not found or not has_company_permission(r.company_id,'purchases') or not has_company_permission(r.company_id,'inventory') or not has_company_permission(r.company_id,'accounting') then raise exception 'Access denied';end if;
 select * into p from goods_receipt_postings where receipt_id=r.id for update;
 if not found then raise exception 'Posted receipt not found';end if;if p.status='reversed' then return p.reversal_id;end if;
 if length(trim(coalesce(reason,'')))<3 then raise exception 'Reversal reason required';end if;
 if exists(select 1 from goods_receipt_partial_bills l join purchase_bills b on b.id=l.bill_id where l.receipt_id=r.id and b.status<>'void') then raise exception 'Delete or void all partial bills before reversing the receipt';end if;
 if exists(select 1 from goods_receipt_bill_links l join purchase_bills b on b.id=l.bill_id where l.receipt_id=r.id and b.status<>'void') then raise exception 'Delete the linked bill draft or void its posted bill first';end if;
 perform 1 from products where id in(select (value->>'product_id')::uuid from jsonb_array_elements(p.items)) order by id for update;
 for item in select value from jsonb_array_elements(p.items) loop
  if exists(select 1 from inventory_revaluations v where v.company_id=r.company_id and v.product_id=(item->>'product_id')::uuid and v.status='posted' and v.movement_count>=(item->>'previous_count')::bigint+1) then raise exception 'Later inventory valuation exists; reverse its adjustment first or review source correction';end if;
  select count(*) into movement_count from stock_movements where company_id=r.company_id and product_id=(item->>'product_id')::uuid;
  if movement_count<>(item->>'previous_count')::bigint+1 then raise exception 'Later stock activity exists; receipt reversal needs a reviewed valuation adjustment';end if;
 end loop;
 for item in select value from jsonb_array_elements(p.items) loop
  insert into stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,reference,created_by) values(r.company_id,r.warehouse_id,(item->>'product_id')::uuid,'return_out',current_date,(item->>'quantity')::numeric,(item->>'unit_cost')::numeric,'goods_receipt_void',r.id,reason,auth.uid());
  perform set_config('cloudledger.allow_stock_quantity','on',true);update products set average_cost=(item->>'previous_average')::numeric where id=(item->>'product_id')::uuid;perform set_config('cloudledger.allow_stock_quantity','',true);
 end loop;
 perform set_config('cloudledger.posting_permission','accounting',true);perform set_config('cloudledger.receipt_reversal_id',r.id::text,true);result:=create_journal_reversal(p.journal_entry_id,reason);perform set_config('cloudledger.receipt_reversal_id','',true);
 update goods_receipt_postings set status='reversed',reversal_id=result where id=p.id;return result;
end $$;


create or replace function public.reverse_goods_delivery(target_delivery uuid,reason text) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare r goods_document_drafts%rowtype; p goods_delivery_postings%rowtype; item jsonb; result uuid; movement_count bigint;
begin
 select * into r from goods_document_drafts where id=target_delivery for update;
 if not found or not has_company_permission(r.company_id,'sales') or not has_company_permission(r.company_id,'inventory') or not has_company_permission(r.company_id,'accounting') then raise exception 'Access denied';end if;
 select * into p from goods_delivery_postings where delivery_id=r.id for update;
 if not found then raise exception 'Posted delivery not found';end if;if p.status='reversed' then return p.reversal_id;end if;
 if length(trim(coalesce(reason,'')))<3 then raise exception 'Reversal reason required';end if;
 if exists(select 1 from goods_delivery_partial_invoices l join sales_invoices i on i.id=l.invoice_id where l.delivery_id=r.id and i.status<>'void') then raise exception 'Delete or void all allocated invoices before reversing the dispatch';end if;
 if exists(select 1 from goods_delivery_invoice_links l join sales_invoices b on b.id=l.invoice_id where l.delivery_id=r.id and b.status<>'void') then raise exception 'Delete the linked invoice draft or void its posted invoice first';end if;
 perform 1 from products where id in(select (value->>'product_id')::uuid from jsonb_array_elements(p.items)) order by id for update;
 for item in select value from jsonb_array_elements(p.items) loop
  if exists(select 1 from inventory_revaluations v where v.company_id=r.company_id and v.product_id=(item->>'product_id')::uuid and v.status='posted' and v.movement_count>=(item->>'previous_count')::bigint+1) then raise exception 'Later inventory valuation exists; reverse its adjustment first or review source correction';end if;
  select count(*) into movement_count from stock_movements where company_id=r.company_id and product_id=(item->>'product_id')::uuid;
  if movement_count<>(item->>'previous_count')::bigint+1 then raise exception 'Later stock activity exists; delivery reversal needs a reviewed valuation adjustment';end if;
 end loop;
 for item in select value from jsonb_array_elements(p.items) loop
  insert into stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,reference,created_by) values(r.company_id,r.warehouse_id,(item->>'product_id')::uuid,'return_in',current_date,(item->>'quantity')::numeric,(item->>'unit_cost')::numeric,'goods_delivery_void',r.id,reason,auth.uid());
  perform set_config('cloudledger.allow_stock_quantity','on',true);update products set average_cost=(item->>'previous_average')::numeric where id=(item->>'product_id')::uuid;perform set_config('cloudledger.allow_stock_quantity','',true);
 end loop;
 perform set_config('cloudledger.posting_permission','accounting',true);perform set_config('cloudledger.delivery_reversal_id',r.id::text,true);result:=create_journal_reversal(p.journal_entry_id,reason);perform set_config('cloudledger.delivery_reversal_id','',true);
 update goods_delivery_postings set status='reversed',reversal_id=result where id=p.id;return result;
end $$;

commit;
