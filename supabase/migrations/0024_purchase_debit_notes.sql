-- Audit-safe purchase returns and supplier debit notes linked to posted bills.
begin;

insert into public.accounts(company_id,code,name,type,system_account)
select c.id,'5050','Purchase Return Variance','expense',true from public.companies c
on conflict(company_id,code) do nothing;

create table public.purchase_debit_notes (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict, warehouse_id uuid references public.warehouses(id) on delete restrict,
  supplier_id uuid not null references public.contacts(id) on delete restrict, bill_id uuid not null references public.purchase_bills(id) on delete restrict,
  debit_number bigint generated always as identity, debit_date date not null default current_date,
  reason text not null check(length(trim(reason))>=3), status public.business_document_status not null default 'draft',
  subtotal numeric(18,2) not null default 0, gst_total numeric(18,2) not null default 0, total numeric(18,2) not null default 0,
  journal_entry_id uuid references public.journal_entries(id), created_by uuid not null references auth.users(id),
  posted_at timestamptz, created_at timestamptz not null default now()
);
create table public.purchase_debit_note_lines (
  id uuid primary key default gen_random_uuid(), debit_note_id uuid not null references public.purchase_debit_notes(id) on delete cascade,
  bill_line_id uuid not null references public.purchase_bill_lines(id) on delete restrict,
  product_id uuid references public.products(id) on delete restrict, expense_account_id uuid references public.accounts(id) on delete restrict,
  description text not null, quantity numeric(18,3) not null check(quantity>0), unit_price numeric(18,2) not null check(unit_price>=0),
  gst_rate numeric(5,2) not null check(gst_rate between 0 and 100),
  subtotal numeric(18,2) generated always as (round(quantity*unit_price,2)) stored,
  gst_amount numeric(18,2) generated always as (round(quantity*unit_price*gst_rate/100,2)) stored,
  total numeric(18,2) generated always as (round(quantity*unit_price*(1+gst_rate/100),2)) stored
);
create index purchase_debit_notes_bill_idx on public.purchase_debit_notes(bill_id,status);
create index purchase_debit_note_lines_bill_line_idx on public.purchase_debit_note_lines(bill_line_id);

alter table public.purchase_debit_notes enable row level security;
alter table public.purchase_debit_note_lines enable row level security;
create policy "members read purchase debit notes" on public.purchase_debit_notes for select using(public.is_company_member(company_id));
create policy "purchase staff manage debit notes" on public.purchase_debit_notes for all
  using(public.has_company_permission(company_id,'purchases')) with check(public.has_company_permission(company_id,'purchases'));
create policy "members read purchase debit lines" on public.purchase_debit_note_lines for select
  using(exists(select 1 from public.purchase_debit_notes n where n.id=debit_note_id and public.is_company_member(n.company_id)));
create policy "purchase staff manage debit lines" on public.purchase_debit_note_lines for all
  using(exists(select 1 from public.purchase_debit_notes n where n.id=debit_note_id and public.has_company_permission(n.company_id,'purchases')))
  with check(exists(select 1 from public.purchase_debit_notes n where n.id=debit_note_id and public.has_company_permission(n.company_id,'purchases')));

create or replace function public.protect_purchase_debit_note()
returns trigger language plpgsql set search_path=public as $$
begin
  if tg_op='INSERT' then
    if new.status<>'draft' or new.subtotal<>0 or new.gst_total<>0 or new.total<>0 or new.journal_entry_id is not null then raise exception 'New debit note must start as an empty draft'; end if;
    return new;
  end if;
  if old.status='draft' then
    if tg_op='UPDATE' and new.status<>old.status and coalesce(current_setting('cloudledger.allow_debit_note_transition',true),'')<>'on' then raise exception 'Use the controlled debit-note workflow'; end if;
    return case when tg_op='DELETE' then old else new end;
  end if;
  if tg_op='UPDATE' and old.status='posted' and new.status='void' and current_setting('cloudledger.allow_debit_note_transition',true)='on'
    and (to_jsonb(new)-'status')=(to_jsonb(old)-'status') then return new; end if;
  raise exception 'Posted debit note is immutable';
end; $$;
create trigger purchase_debit_note_immutable before insert or update or delete on public.purchase_debit_notes for each row execute function public.protect_purchase_debit_note();

create or replace function public.protect_purchase_debit_note_lines()
returns trigger language plpgsql set search_path=public as $$
declare parent_status public.business_document_status;
begin
  select status into parent_status from public.purchase_debit_notes where id=coalesce(new.debit_note_id,old.debit_note_id);
  if parent_status is distinct from 'draft' then raise exception 'Posted debit-note lines are immutable'; end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;
create trigger purchase_debit_note_lines_immutable before insert or update or delete on public.purchase_debit_note_lines for each row execute function public.protect_purchase_debit_note_lines();

create or replace function public.validate_purchase_debit_note_line()
returns trigger language plpgsql set search_path=public as $$
declare n public.purchase_debit_notes%rowtype; source public.purchase_bill_lines%rowtype; allocated numeric(18,3); exclude_line uuid;
begin
  select * into n from public.purchase_debit_notes where id=new.debit_note_id and status='draft';
  select * into source from public.purchase_bill_lines where id=new.bill_line_id and bill_id=n.bill_id;
  if n.id is null or source.id is null or new.product_id is distinct from source.product_id
    or new.expense_account_id is distinct from source.expense_account_id or new.unit_price<>source.unit_price or new.gst_rate<>source.gst_rate then
    raise exception 'Debit-note line must match its original purchase-bill line';
  end if;
  if tg_op='UPDATE' then exclude_line:=old.id; end if;
  select coalesce(sum(nl.quantity),0) into allocated from public.purchase_debit_note_lines nl
  join public.purchase_debit_notes h on h.id=nl.debit_note_id
  where nl.bill_line_id=source.id and h.status<>'void' and (exclude_line is null or nl.id<>exclude_line);
  if allocated+new.quantity>source.quantity then raise exception 'Returned quantity exceeds the original purchase bill'; end if;
  return new;
end; $$;
create trigger purchase_debit_note_line_valid before insert or update on public.purchase_debit_note_lines
for each row execute function public.validate_purchase_debit_note_line();

create or replace view public.purchase_bill_return_progress with (security_invoker=true) as
select b.company_id,l.bill_id,l.id as bill_line_id,l.product_id,l.expense_account_id,l.description,l.quantity as purchased_quantity,l.unit_price,l.gst_rate,
  coalesce(sum(case when n.status<>'void' then nl.quantity else 0 end),0)::numeric(18,3) returned_quantity,
  (l.quantity-coalesce(sum(case when n.status<>'void' then nl.quantity else 0 end),0))::numeric(18,3) remaining_quantity
from public.purchase_bill_lines l join public.purchase_bills b on b.id=l.bill_id
left join public.purchase_debit_note_lines nl on nl.bill_line_id=l.id left join public.purchase_debit_notes n on n.id=nl.debit_note_id
group by b.company_id,l.bill_id,l.id,l.product_id,l.expense_account_id,l.description,l.quantity,l.unit_price,l.gst_rate;
revoke all on public.purchase_bill_return_progress from public,anon;
grant select on public.purchase_bill_return_progress to authenticated;

create or replace function public.prevent_bill_void_with_debit_notes()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.status='void' and old.status is distinct from 'void'
    and exists(select 1 from public.purchase_debit_notes n where n.bill_id=old.id and n.status<>'void') then
    raise exception 'Void or delete the linked debit notes before voiding this bill';
  end if;
  return new;
end; $$;
create trigger bill_debit_note_void_guard before update on public.purchase_bills for each row execute function public.prevent_bill_void_with_debit_notes();

create or replace function public.prevent_payment_above_net_bill()
returns trigger language plpgsql set search_path=public as $$
declare posted_debits numeric(18,2);
begin
  if new.amount_paid>old.amount_paid then
    select coalesce(sum(n.total),0) into posted_debits from public.purchase_debit_notes n where n.bill_id=old.id and n.status='posted';
    if new.amount_paid>old.total-posted_debits then raise exception 'Payment exceeds bill balance after debit notes'; end if;
  end if;
  return new;
end; $$;
create trigger bill_net_payment_guard before update on public.purchase_bills for each row execute function public.prevent_payment_above_net_bill();

create or replace function public.create_purchase_debit_note(target_bill uuid,target_reason text,return_lines jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare bill public.purchase_bills%rowtype; new_note uuid; requested_count integer; valid_count integer;
begin
  select * into bill from public.purchase_bills where id=target_bill and status in ('posted','part_paid','paid') for update;
  if bill.id is null or not public.has_company_permission(bill.company_id,'purchases') then raise exception 'Posted bill not found or purchase access denied'; end if;
  if nullif(trim(target_reason),'') is null or length(trim(target_reason))<3 then raise exception 'Return reason is required'; end if;
  if jsonb_typeof(return_lines)<>'array' or jsonb_array_length(return_lines)=0 then raise exception 'Select at least one quantity to return'; end if;
  if exists(select 1 from jsonb_array_elements(return_lines) x group by x->>'line_id' having count(*)>1) then raise exception 'A purchase-bill line cannot be submitted twice'; end if;
  perform 1 from public.purchase_bill_lines where bill_id=bill.id for update;
  requested_count:=jsonb_array_length(return_lines);
  select count(*) into valid_count from jsonb_array_elements(return_lines) x
  join public.purchase_bill_return_progress p on p.bill_line_id=(x->>'line_id')::uuid and p.bill_id=bill.id
  where (x->>'quantity')::numeric>0 and (x->>'quantity')::numeric<=p.remaining_quantity;
  if valid_count<>requested_count then raise exception 'Return contains an invalid line or quantity above the remaining balance'; end if;
  insert into public.purchase_debit_notes(company_id,branch_id,warehouse_id,supplier_id,bill_id,debit_date,reason,created_by)
  values(bill.company_id,bill.branch_id,bill.warehouse_id,bill.supplier_id,bill.id,current_date,trim(target_reason),auth.uid()) returning id into new_note;
  insert into public.purchase_debit_note_lines(debit_note_id,bill_line_id,product_id,expense_account_id,description,quantity,unit_price,gst_rate)
  select new_note,l.id,l.product_id,l.expense_account_id,l.description,(x->>'quantity')::numeric,l.unit_price,l.gst_rate
  from jsonb_array_elements(return_lines) x join public.purchase_bill_lines l on l.id=(x->>'line_id')::uuid where l.bill_id=bill.id;
  return new_note;
end; $$;

create or replace function public.post_purchase_debit_note(target_note uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare n public.purchase_debit_notes%rowtype; sub numeric(18,2); tax numeric(18,2); grand numeric(18,2);
  ap uuid; inventory uuid; input_gst uuid; variance_account uuid; new_journal uuid; stock_cost numeric(18,2); expense_cost numeric(18,2); variance numeric(18,2); line record;
begin
  select * into n from public.purchase_debit_notes where id=target_note and status='draft' for update;
  if n.id is null or not public.has_company_permission(n.company_id,'purchases') then raise exception 'Debit-note draft not found or purchase access denied'; end if;
  perform 1 from public.purchase_bill_lines where bill_id=n.bill_id for update;
  if exists(select 1 from public.purchase_debit_note_lines nl join public.purchase_bill_return_progress p on p.bill_line_id=nl.bill_line_id
    where nl.debit_note_id=n.id and p.returned_quantity>p.purchased_quantity) then raise exception 'Returned quantity exceeds the original purchase bill'; end if;
  select coalesce(sum(subtotal),0),coalesce(sum(gst_amount),0),coalesce(sum(total),0) into sub,tax,grand from public.purchase_debit_note_lines where debit_note_id=n.id;
  if grand<=0 then raise exception 'Debit note requires at least one positive line'; end if;
  select id into ap from public.accounts where company_id=n.company_id and code='2000';
  select id into inventory from public.accounts where company_id=n.company_id and code='1200';
  select id into input_gst from public.accounts where company_id=n.company_id and code='1150';
  select id into variance_account from public.accounts where company_id=n.company_id and code='5050';
  if variance_account is null then
    insert into public.accounts(company_id,code,name,type,system_account)
    values(n.company_id,'5050','Purchase Return Variance','expense',true)
    on conflict(company_id,code) do update set name=excluded.name
    returning id into variance_account;
  end if;
  select coalesce(sum(case when nl.expense_account_id is null and not p.is_service then round(nl.quantity*p.average_cost,2) else 0 end),0),
    coalesce(sum(case when nl.expense_account_id is not null then nl.subtotal else 0 end),0)
    into stock_cost,expense_cost from public.purchase_debit_note_lines nl left join public.products p on p.id=nl.product_id where nl.debit_note_id=n.id;
  variance:=round(sub-expense_cost-stock_cost,2);
  if ap is null or (tax>0 and input_gst is null) or (stock_cost>0 and inventory is null) then raise exception 'Required system accounts are missing'; end if;
  insert into public.journal_entries(company_id,branch_id,entry_date,reference,description,created_by)
  values(n.company_id,n.branch_id,n.debit_date,'DN-'||lpad(n.debit_number::text,6,'0'),'Purchase return: '||n.reason,auth.uid()) returning id into new_journal;
  insert into public.journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,ap,'Supplier debit',grand,0);
  insert into public.journal_lines(entry_id,account_id,description,debit,credit)
    select new_journal,nl.expense_account_id,'Expense reversal: '||nl.description,0,sum(nl.subtotal)
    from public.purchase_debit_note_lines nl where nl.debit_note_id=n.id and nl.expense_account_id is not null group by nl.expense_account_id,nl.description;
  if stock_cost>0 then insert into public.journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,inventory,'Inventory returned',0,stock_cost); end if;
  if tax>0 then insert into public.journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,input_gst,'Input GST reversal',0,tax); end if;
  if variance>0 then insert into public.journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,variance_account,'Purchase return variance',0,variance);
  elsif variance<0 then insert into public.journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,variance_account,'Purchase return variance',-variance,0); end if;
  perform set_config('cloudledger.posting_permission','purchases',true);
  perform public.post_journal(new_journal);
  for line in select nl.product_id,nl.quantity,p.average_cost,p.is_service from public.purchase_debit_note_lines nl join public.products p on p.id=nl.product_id where nl.debit_note_id=n.id loop
    if not line.is_service then
      if n.warehouse_id is null then raise exception 'Purchase return warehouse is missing'; end if;
      insert into public.stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,reference,created_by)
      values(n.company_id,n.warehouse_id,line.product_id,'return_out',n.debit_date,line.quantity,line.average_cost,'purchase_debit_note',n.id,'BILL-'||n.bill_id,auth.uid());
    end if;
  end loop;
  perform set_config('cloudledger.allow_debit_note_transition','on',true);
  update public.purchase_debit_notes set subtotal=sub,gst_total=tax,total=grand,status='posted',journal_entry_id=new_journal,posted_at=now() where id=n.id;
  return new_journal;
end; $$;

create or replace function public.void_purchase_debit_note(target_note uuid,target_reason text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare n public.purchase_debit_notes%rowtype; reversal uuid; line record;
begin
  select * into n from public.purchase_debit_notes where id=target_note and status='posted' for update;
  if n.id is null or not public.has_company_permission(n.company_id,'purchases') then raise exception 'Posted debit note not found or purchase access denied'; end if;
  for line in select warehouse_id,product_id,quantity,unit_cost from public.stock_movements where source_type='purchase_debit_note' and source_id=n.id and movement_type='return_out' loop
    insert into public.stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,reference,created_by)
    values(n.company_id,line.warehouse_id,line.product_id,'return_in',current_date,line.quantity,line.unit_cost,'purchase_debit_note_void',n.id,target_reason,auth.uid());
  end loop;
  perform set_config('cloudledger.posting_permission','purchases',true);
  reversal:=public.create_journal_reversal(n.journal_entry_id,target_reason);
  perform set_config('cloudledger.allow_debit_note_transition','on',true);
  update public.purchase_debit_notes set status='void' where id=n.id;
  return reversal;
end; $$;

create or replace function public.get_payable_aging(target_company uuid,as_of date default current_date)
returns table(contact_name text,current_amount numeric,days_1_30 numeric,days_31_60 numeric,days_61_90 numeric,days_over_90 numeric,total_due numeric)
language plpgsql stable security definer set search_path=public as $$
begin
  if as_of is null then raise exception 'As-of date is required'; end if;
  if not public.is_company_member(target_company) then raise exception 'Access denied'; end if;
  return query with document_balances as (
    select b.supplier_id,b.due_date,greatest(b.total
      -coalesce((select sum(p.amount) from public.payments p where p.purchase_bill_id=b.id and p.status='posted' and p.direction='payment' and p.payment_date<=as_of),0)
      -coalesce((select sum(n.total) from public.purchase_debit_notes n where n.bill_id=b.id and n.status='posted' and n.debit_date<=as_of),0),0)::numeric balance
    from public.purchase_bills b where b.company_id=target_company and b.bill_date<=as_of and b.status in ('posted','part_paid','paid')
  )
  select c.name,coalesce(sum(d.balance) filter(where as_of-d.due_date<=0),0),coalesce(sum(d.balance) filter(where as_of-d.due_date between 1 and 30),0),
    coalesce(sum(d.balance) filter(where as_of-d.due_date between 31 and 60),0),coalesce(sum(d.balance) filter(where as_of-d.due_date between 61 and 90),0),
    coalesce(sum(d.balance) filter(where as_of-d.due_date>90),0),sum(d.balance)
  from document_balances d join public.contacts c on c.id=d.supplier_id and c.company_id=target_company where d.balance>0 group by c.id,c.name order by c.name;
end; $$;

create trigger purchase_debit_note_audit after insert or update or delete on public.purchase_debit_notes for each row execute function public.write_audit_log();
revoke all on function public.create_purchase_debit_note(uuid,text,jsonb) from public,anon;
revoke all on function public.post_purchase_debit_note(uuid) from public,anon;
revoke all on function public.void_purchase_debit_note(uuid,text) from public,anon;
grant execute on function public.create_purchase_debit_note(uuid,text,jsonb) to authenticated;
grant execute on function public.post_purchase_debit_note(uuid) to authenticated;
grant execute on function public.void_purchase_debit_note(uuid,text) to authenticated;
commit;
