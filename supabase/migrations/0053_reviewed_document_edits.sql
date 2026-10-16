begin;
-- Single transaction for editing an existing draft, retaining line identities and RLS.
create function public.update_reviewed_draft(target_company uuid, record_kind text, target_record uuid, expected_header jsonb, header jsonb, expected_lines jsonb, items jsonb)
returns uuid language plpgsql security invoker set search_path=public,pg_temp as $$
declare tbl text; child text; parent text; permission text; hcols text[]; lcols text[]; source jsonb; old_header jsonb; old_lines jsonb; item jsonb; assignments text; n numeric; key text; changed integer;
begin
 if auth.uid() is null then raise exception 'Authenticated session required';end if;
 case record_kind
 when 'quotations' then tbl:='quotations';child:='quotation_lines';parent:='quotation_id';permission:='sales';hcols:=array['quotation_date','valid_until','notes'];lcols:=array['description','quantity','unit_price','gst_rate'];
 when 'sales_orders' then tbl:='sales_orders';child:='sales_order_lines';parent:='sales_order_id';permission:='sales';hcols:=array['order_date','promised_date','customer_reference','notes'];lcols:=array['description','quantity','unit_price','gst_rate'];
 when 'purchase_orders' then tbl:='purchase_orders';child:='purchase_order_lines';parent:='purchase_order_id';permission:='purchases';hcols:=array['order_date','expected_date','supplier_reference','notes'];lcols:=array['description','quantity','unit_price','gst_rate'];
 when 'sales_credit_notes' then tbl:='sales_credit_notes';child:='sales_credit_note_lines';parent:='credit_note_id';permission:='sales';hcols:=array['credit_date','reason'];lcols:=array['quantity'];
 when 'purchase_debit_notes' then tbl:='purchase_debit_notes';child:='purchase_debit_note_lines';parent:='debit_note_id';permission:='purchases';hcols:=array['debit_date','reason'];lcols:=array['quantity'];
 when 'journal_entries' then tbl:='journal_entries';child:='journal_lines';parent:='entry_id';permission:='accounting';hcols:=array['entry_date','reference','description'];lcols:=array['description','debit','credit'];
 else raise exception 'Unsupported draft type';
 end case;
 if not has_company_permission(target_company,permission) then raise exception 'Company permission denied';end if;
 execute format('select to_jsonb(t) from public.%I t where id=$1 and company_id=$2 for update',tbl) into source using target_record,target_company;
 if source is null or source->>'status'<>'draft' then raise exception 'Only an accessible draft can be edited';end if;
 if record_kind='journal_entries' and (left(coalesce(source->>'description',''),16)='[Expense claim] ' or source->>'reversal_of' is not null or exists(select 1 from sales_invoices where journal_entry_id=target_record) or exists(select 1 from purchase_bills where journal_entry_id=target_record) or exists(select 1 from payments where journal_entry_id=target_record) or exists(select 1 from payroll_runs where journal_entry_id=target_record)) then raise exception 'Edit this record from its source document';end if;
 if record_kind='sales_credit_notes' then perform id from sales_invoice_lines where invoice_id=(source->>'invoice_id')::uuid order by id for update;end if;
 if record_kind='purchase_debit_notes' then perform id from purchase_bill_lines where bill_id=(source->>'bill_id')::uuid order by id for update;end if;
 select jsonb_object_agg(k,v) into old_header from jsonb_each(source) e(k,v) where k=any(hcols);
 if old_header is distinct from expected_header then raise exception 'Record changed; reopen before editing';end if;
 if header is null or jsonb_typeof(header)<>'object' or exists(select 1 from jsonb_object_keys(header) k where not k=any(hcols)) or (select count(*) from jsonb_object_keys(header))<>cardinality(hcols) then raise exception 'Invalid draft header';end if;
 for key in select unnest(hcols) loop
  if key like '%_date' and key not in ('valid_until','promised_date','expected_date') and nullif(header->>key,'') is null then raise exception 'Document date required';end if;
 end loop;
 if record_kind='quotations' and (header->>'valid_until')::date<(header->>'quotation_date')::date or record_kind='sales_orders' and (header->>'promised_date')::date<(header->>'order_date')::date or record_kind='purchase_orders' and (header->>'expected_date')::date<(header->>'order_date')::date then raise exception 'End date cannot precede document date';end if;
 if record_kind in ('sales_credit_notes','purchase_debit_notes') and nullif(trim(header->>'reason'),'') is null then raise exception 'Return reason required';end if;
 -- Lock every line before comparing the review snapshot. No deletion/replacement of IDs.
 execute format('select id from public.%I where %I=$1 order by id for update',child,parent) using target_record;
 execute format('select coalesce(jsonb_agg(p.fields order by t.id),''[]''::jsonb) from public.%I t cross join lateral (select jsonb_object_agg(k,v) fields from jsonb_each(to_jsonb(t)) e(k,v) where k=any($2)) p where t.%I=$1',child,parent) into old_lines using target_record,lcols||array['id'];
 if old_lines is distinct from expected_lines then raise exception 'Lines changed; reopen before editing';end if;
 if items is null or jsonb_typeof(items)<>'array' or jsonb_array_length(items)=0 or jsonb_array_length(items)<>jsonb_array_length(old_lines) then raise exception 'Edit must retain every existing line';end if;
 if (select count(distinct v->>'id') from jsonb_array_elements(items) v)<>jsonb_array_length(items) then raise exception 'Duplicate line identity';end if;
 for item in select value from jsonb_array_elements(items) loop
  if not exists(select 1 from jsonb_array_elements(old_lines) v where v->>'id'=item->>'id') or exists(select 1 from jsonb_object_keys(item) k where not k=any(lcols||array['id'])) or (select count(*) from jsonb_object_keys(item))<>cardinality(lcols)+1 then raise exception 'Invalid line fields or identity';end if;
  for key in select unnest(lcols) loop
   if key='description' then
    if record_kind<>'journal_entries' and nullif(trim(item->>key),'') is null then raise exception 'Line description required';end if;
   else
    n:=(item->>key)::numeric;
    if n is null or n::text in ('NaN','Infinity','-Infinity') or n<0 or n>=1000000000000000 or n<>round(n,case when key='quantity' then 3 else 2 end) or (key='quantity' and n<=0) or (key='gst_rate' and n>100) then raise exception 'Invalid quantity, amount or GST';end if;
   end if;
  end loop;
  if record_kind='journal_entries' and (item->>'debit')::numeric>0 and (item->>'credit')::numeric>0 then raise exception 'A journal line cannot have both debit and credit';end if;
 end loop;
 select string_agg(format('%I=x.%I',k,k),',') into assignments from unnest(hcols) k;
 execute format('update public.%I t set %s from jsonb_populate_record(null::public.%I,$1) x where t.id=$2 and t.company_id=$3 and t.status=''draft''',tbl,assignments,tbl) using header,target_record,target_company;
 get diagnostics changed=row_count;if changed<>1 then raise exception 'Draft update denied';end if;
 select string_agg(format('%I=x.%I',k,k),',') into assignments from unnest(lcols) k;
 for item in select value from jsonb_array_elements(items) loop
  execute format('update public.%I t set %s from jsonb_populate_record(null::public.%I,$1) x where t.id=$2 and t.%I=$3',child,assignments,child,parent) using item,(item->>'id')::uuid,target_record;
  get diagnostics changed=row_count;if changed<>1 then raise exception 'Draft line update denied';end if;
 end loop;
 return target_record;
end $$;
revoke all on function public.update_reviewed_draft(uuid,text,uuid,jsonb,jsonb,jsonb,jsonb) from public,anon;
grant execute on function public.update_reviewed_draft(uuid,text,uuid,jsonb,jsonb,jsonb,jsonb) to authenticated;
create function public.update_reviewed_master(target_company uuid,record_kind text,target_record uuid,expected_values jsonb,new_values jsonb)
returns uuid language plpgsql security invoker set search_path=public,pg_temp as $$
declare cols text[]; source jsonb; snapshot jsonb; assignments text; n numeric; key text; changed integer;
begin
 if auth.uid() is null then raise exception 'Authenticated session required';end if;
 case record_kind
 when 'employees' then cols:=array['full_name','designation','department','phone','email','address','base_salary','monthly_income_tax','monthly_eobi','monthly_sessi','tax_enabled','eobi_enabled','sessi_enabled','active'];
 when 'attendance' then cols:=array['status','check_in','check_out','overtime_hours','notes'];
 when 'leave_requests' then cols:=array['leave_type','start_date','end_date','paid','reason'];
 when 'bank_accounts' then cols:=array['name','bank_name','account_number','iban','active'];
 when 'branches' then cols:=array['name','city','active'];
 else raise exception 'Unsupported master record';end case;
 if record_kind in ('employees','attendance','leave_requests') then
  if not has_company_permission(target_company,'payroll') then raise exception 'Payroll permission denied';end if;
 elsif not can_write_company(target_company) then raise exception 'Company write permission denied';end if;
 execute format('select to_jsonb(t) from public.%I t where id=$1 and company_id=$2 for update',record_kind) into source using target_record,target_company;
 if source is null then raise exception 'Record not found or access denied';end if;
 select jsonb_object_agg(k,v) into snapshot from jsonb_each(source) e(k,v) where k=any(cols);
 if snapshot is distinct from expected_values then raise exception 'Record changed; reopen before editing';end if;
 if new_values is null or jsonb_typeof(new_values)<>'object' or exists(select 1 from jsonb_object_keys(new_values) k where not k=any(cols)) or (select count(*) from jsonb_object_keys(new_values))<>cardinality(cols) then raise exception 'Invalid master fields';end if;
 if record_kind='employees' and nullif(trim(new_values->>'full_name'),'') is null or record_kind in ('bank_accounts','branches') and nullif(trim(new_values->>'name'),'') is null then raise exception 'Name required';end if;
 for key in select unnest(cols) loop
  if key in ('base_salary','monthly_income_tax','monthly_eobi','monthly_sessi','overtime_hours') then
   n:=(new_values->>key)::numeric;
   if n is null or n::text in ('NaN','Infinity','-Infinity') or n<0 or n<>round(n,2) then raise exception 'Invalid salary, deduction or overtime';end if;
  end if;
 end loop;
 if record_kind='attendance' then
  if (new_values->>'status') is null or (new_values->>'status') not in ('present','absent','leave','holiday') then raise exception 'Invalid attendance status';end if;
  if (new_values->>'check_out')::time <= (new_values->>'check_in')::time then raise exception 'Check-out must be after check-in';end if;
 end if;
 if record_kind='leave_requests' then
  if source->>'status'<>'pending' then raise exception 'Reviewed leave is locked';end if;
  if nullif(trim(new_values->>'leave_type'),'') is null or (new_values->>'start_date') is null or (new_values->>'end_date') is null or (new_values->>'end_date')::date<(new_values->>'start_date')::date then raise exception 'Valid leave type and dates required';end if;
  perform id from employees where id=(source->>'employee_id')::uuid for update;
  if exists(select 1 from leave_requests where employee_id=(source->>'employee_id')::uuid and id<>target_record and status in ('pending','approved') and daterange(start_date,end_date,'[]') && daterange((new_values->>'start_date')::date,(new_values->>'end_date')::date,'[]')) then raise exception 'Leave dates overlap an existing request';end if;
 end if;
 select string_agg(format('%I=x.%I',k,k),',') into assignments from unnest(cols) k;
 execute format('update public.%I t set %s from jsonb_populate_record(null::public.%I,$1) x where t.id=$2 and t.company_id=$3',record_kind,assignments,record_kind) using new_values,target_record,target_company;
 get diagnostics changed=row_count;if changed<>1 then raise exception 'Record update denied';end if;
 return target_record;
end $$;
revoke all on function public.update_reviewed_master(uuid,text,uuid,jsonb,jsonb) from public,anon;
grant execute on function public.update_reviewed_master(uuid,text,uuid,jsonb,jsonb) to authenticated;
create trigger reviewed_employee_edit_audit after update on public.employees for each row execute function public.write_audit_log();
create trigger reviewed_attendance_edit_audit after update on public.attendance for each row execute function public.write_audit_log();
create trigger reviewed_leave_edit_audit after update on public.leave_requests for each row execute function public.write_audit_log();
create trigger reviewed_bank_edit_audit after update on public.bank_accounts for each row execute function public.write_audit_log();
create trigger reviewed_branch_edit_audit after update on public.branches for each row execute function public.write_audit_log();
create function public.update_reviewed_payroll_period(target_company uuid,target_run uuid,expected_start date,expected_end date,new_start date,new_end date)
returns uuid language plpgsql security invoker set search_path=public,pg_temp as $$
declare r payroll_runs%rowtype;
begin
 if auth.uid() is null or not has_company_permission(target_company,'payroll') then raise exception 'Payroll permission denied';end if;
 select * into r from payroll_runs where id=target_run and company_id=target_company for update;
 if not found or r.status<>'draft' then raise exception 'Only a payroll draft can be recalculated';end if;
 if r.period_start is distinct from expected_start or r.period_end is distinct from expected_end then raise exception 'Payroll changed; reopen before editing';end if;
 if new_start is null or new_end is null or new_end<new_start then raise exception 'Valid payroll period required';end if;
 update payroll_runs set period_start=new_start,period_end=new_end where id=r.id;
 perform prepare_payroll_run(r.id);
 return r.id;
end $$;
revoke all on function public.update_reviewed_payroll_period(uuid,uuid,date,date,date,date) from public,anon;
grant execute on function public.update_reviewed_payroll_period(uuid,uuid,date,date,date,date) to authenticated;
notify pgrst,'reload schema';
commit;
