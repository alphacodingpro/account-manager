begin;
create function public.post_inventory_writeoff(target_company uuid,target_warehouse uuid,target_product uuid,target_quantity numeric,loss_account uuid,reason text)
returns uuid language plpgsql security invoker set search_path=public as $$
declare cost numeric; value numeric; inventory uuid; result uuid; branch uuid;
begin
 if not has_company_permission(target_company,'inventory') or not has_company_permission(target_company,'accounting') then raise exception 'Inventory and accounting permission required';end if;
 if target_quantity is null or target_quantity::text in ('NaN','Infinity','-Infinity') or target_quantity<=0 or target_quantity<>round(target_quantity,3) or nullif(trim(reason),'') is null then raise exception 'Valid quantity and reason required';end if;
 select average_cost into cost from products where id=target_product and company_id=target_company and active and not is_service for update;
 if not found then raise exception 'Invalid stock product';end if;
 select branch_id into branch from warehouses where id=target_warehouse and company_id=target_company and active;
 if not found then raise exception 'Invalid warehouse';end if;
 if not exists(select 1 from accounts where id=loss_account and company_id=target_company and active and type='expense') then raise exception 'Invalid loss expense account';end if;
 select id into inventory from accounts where company_id=target_company and code='1200' and active;
 value:=round(cost*target_quantity,2);if inventory is null or value<=0 then raise exception 'Inventory account and positive stock valuation required';end if;
 insert into journal_entries(company_id,branch_id,entry_date,description,created_by) values(target_company,branch,current_date,'Inventory write-off: '||trim(reason),auth.uid()) returning id into result;
 insert into journal_lines(entry_id,account_id,debit,credit) values(result,loss_account,value,0),(result,inventory,0,value);
 insert into stock_movements(company_id,warehouse_id,product_id,movement_type,quantity,unit_cost,source_type,source_id,reference,created_by) values(target_company,target_warehouse,target_product,'adjustment_out',target_quantity,cost,'inventory_writeoff',result,trim(reason),auth.uid());
 perform post_journal(result);return result;
end $$;
create function public.reverse_inventory_writeoff(target_entry uuid) returns uuid language plpgsql security invoker set search_path=public as $$
declare source journal_entries%rowtype; movement stock_movements%rowtype; result uuid;
begin
 select * into source from journal_entries where id=target_entry for update;
 if not found or source.status<>'posted' or not has_company_permission(source.company_id,'inventory') or not has_company_permission(source.company_id,'accounting') then raise exception 'Posted write-off not found or access denied';end if;
 select * into movement from stock_movements where company_id=source.company_id and source_type='inventory_writeoff' and source_id=source.id and movement_type='adjustment_out';
 if not found then raise exception 'Write-off movement missing';end if;
 if exists(select 1 from stock_movements where source_type='inventory_writeoff_reversal' and source_id=source.id) then raise exception 'Already reversed';end if;
 insert into stock_movements(company_id,warehouse_id,product_id,movement_type,quantity,unit_cost,source_type,source_id,reference,created_by) values(source.company_id,movement.warehouse_id,movement.product_id,'adjustment_in',movement.quantity,movement.unit_cost,'inventory_writeoff_reversal',source.id,'Write-off reversal',auth.uid());
 result:=create_journal_reversal(source.id,'Inventory write-off reversal');return result;
end $$;
create function public.guard_writeoff_reversal() returns trigger language plpgsql security invoker set search_path=public as $$
begin
 if old.status='posted' and new.status='reversed' and old.reversal_of is not null and exists(select 1 from stock_movements where source_type='inventory_writeoff' and source_id=old.reversal_of) then raise exception 'A write-off reversal cannot be reversed again; record a new write-off';end if;
 if old.status='posted' and new.status='reversed' and exists(select 1 from stock_movements where source_type='inventory_writeoff' and source_id=old.id) and not exists(select 1 from stock_movements where source_type='inventory_writeoff_reversal' and source_id=old.id) then raise exception 'Reverse this entry from Inventory Write-offs to restore stock';end if;return new;
end $$;
create trigger writeoff_reversal_guard before update of status on journal_entries for each row execute function guard_writeoff_reversal();
revoke all on function public.post_inventory_writeoff(uuid,uuid,uuid,numeric,uuid,text),public.reverse_inventory_writeoff(uuid) from public,anon;
grant execute on function public.post_inventory_writeoff(uuid,uuid,uuid,numeric,uuid,text),public.reverse_inventory_writeoff(uuid) to authenticated;
commit;
