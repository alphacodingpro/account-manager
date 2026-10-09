-- Audit-safe sales returns and credit notes linked to original posted invoices.
begin;

create table public.sales_credit_notes (
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict, customer_id uuid not null references public.contacts(id) on delete restrict,
  invoice_id uuid not null references public.sales_invoices(id) on delete restrict, credit_number bigint generated always as identity,
  credit_date date not null default current_date, reason text not null check(length(trim(reason))>=3), status public.invoice_status not null default 'draft',
  subtotal numeric(18,2) not null default 0, gst_total numeric(18,2) not null default 0, total numeric(18,2) not null default 0,
  journal_entry_id uuid references public.journal_entries(id), created_by uuid not null references auth.users(id),
  posted_at timestamptz, created_at timestamptz not null default now()
);
create table public.sales_credit_note_lines (
  id uuid primary key default gen_random_uuid(), credit_note_id uuid not null references public.sales_credit_notes(id) on delete cascade,
  invoice_line_id uuid not null references public.sales_invoice_lines(id) on delete restrict, product_id uuid references public.products(id) on delete restrict,
  description text not null, quantity numeric(18,3) not null check(quantity>0), unit_price numeric(18,2) not null check(unit_price>=0),
  gst_rate numeric(5,2) not null check(gst_rate between 0 and 100),
  subtotal numeric(18,2) generated always as (round(quantity*unit_price,2)) stored,
  gst_amount numeric(18,2) generated always as (round(quantity*unit_price*gst_rate/100,2)) stored,
  total numeric(18,2) generated always as (round(quantity*unit_price*(1+gst_rate/100),2)) stored
);
create index sales_credit_notes_invoice_idx on public.sales_credit_notes(invoice_id,status);
create index sales_credit_note_lines_invoice_line_idx on public.sales_credit_note_lines(invoice_line_id);

alter table public.sales_credit_notes enable row level security;
alter table public.sales_credit_note_lines enable row level security;
create policy "members read sales credit notes" on public.sales_credit_notes for select using(public.is_company_member(company_id));
create policy "sales staff manage credit notes" on public.sales_credit_notes for all
  using(public.has_company_permission(company_id,'sales')) with check(public.has_company_permission(company_id,'sales'));
create policy "members read sales credit lines" on public.sales_credit_note_lines for select
  using(exists(select 1 from public.sales_credit_notes n where n.id=credit_note_id and public.is_company_member(n.company_id)));
create policy "sales staff manage credit lines" on public.sales_credit_note_lines for all
  using(exists(select 1 from public.sales_credit_notes n where n.id=credit_note_id and public.has_company_permission(n.company_id,'sales')))
  with check(exists(select 1 from public.sales_credit_notes n where n.id=credit_note_id and public.has_company_permission(n.company_id,'sales')));

create or replace function public.protect_sales_credit_note()
returns trigger language plpgsql set search_path=public as $$
begin
  if tg_op='INSERT' then
    if new.status<>'draft' or new.subtotal<>0 or new.gst_total<>0 or new.total<>0 or new.journal_entry_id is not null then raise exception 'New credit note must start as an empty draft'; end if;
    return new;
  end if;
  if old.status='draft' then
    if tg_op='UPDATE' and new.status<>old.status and coalesce(current_setting('cloudledger.allow_credit_note_transition',true),'')<>'on' then raise exception 'Use the controlled credit-note workflow'; end if;
    return case when tg_op='DELETE' then old else new end;
  end if;
  if tg_op='UPDATE' and old.status='posted' and new.status='void' and current_setting('cloudledger.allow_credit_note_transition',true)='on'
    and (to_jsonb(new)-'status')=(to_jsonb(old)-'status') then return new; end if;
  raise exception 'Posted credit note is immutable';
end; $$;
create trigger sales_credit_note_immutable before insert or update or delete on public.sales_credit_notes for each row execute function public.protect_sales_credit_note();

create or replace function public.protect_sales_credit_note_lines()
returns trigger language plpgsql set search_path=public as $$
declare parent_status public.invoice_status;
begin
  select status into parent_status from public.sales_credit_notes where id=coalesce(new.credit_note_id,old.credit_note_id);
  if parent_status is distinct from 'draft' then raise exception 'Posted credit-note lines are immutable'; end if;
  return case when tg_op='DELETE' then old else new end;
end; $$;
create trigger sales_credit_note_lines_immutable before insert or update or delete on public.sales_credit_note_lines for each row execute function public.protect_sales_credit_note_lines();

create or replace function public.validate_sales_credit_note_line()
returns trigger language plpgsql set search_path=public as $$
declare n public.sales_credit_notes%rowtype; source public.sales_invoice_lines%rowtype; allocated numeric(18,3); exclude_line uuid;
begin
  select * into n from public.sales_credit_notes where id=new.credit_note_id and status='draft';
  select * into source from public.sales_invoice_lines where id=new.invoice_line_id and invoice_id=n.invoice_id;
  if n.id is null or source.id is null or new.product_id is distinct from source.product_id
    or new.unit_price<>source.unit_price or new.gst_rate<>source.gst_rate then raise exception 'Credit-note line must match its original invoice line'; end if;
  if tg_op='UPDATE' then exclude_line:=old.id; end if;
  select coalesce(sum(nl.quantity),0) into allocated from public.sales_credit_note_lines nl
  join public.sales_credit_notes h on h.id=nl.credit_note_id
  where nl.invoice_line_id=source.id and h.status<>'void' and (exclude_line is null or nl.id<>exclude_line);
  if allocated+new.quantity>source.quantity then raise exception 'Returned quantity exceeds the original invoice'; end if;
  return new;
end; $$;
create trigger sales_credit_note_line_valid before insert or update on public.sales_credit_note_lines
for each row execute function public.validate_sales_credit_note_line();

create or replace view public.sales_invoice_return_progress with (security_invoker=true) as
select i.company_id,l.invoice_id,l.id as invoice_line_id,l.product_id,l.description,l.quantity as sold_quantity,l.unit_price,l.gst_rate,
  coalesce(sum(case when n.status<>'void' then nl.quantity else 0 end),0)::numeric(18,3) returned_quantity,
  (l.quantity-coalesce(sum(case when n.status<>'void' then nl.quantity else 0 end),0))::numeric(18,3) remaining_quantity
from public.sales_invoice_lines l join public.sales_invoices i on i.id=l.invoice_id
left join public.sales_credit_note_lines nl on nl.invoice_line_id=l.id left join public.sales_credit_notes n on n.id=nl.credit_note_id
group by i.company_id,l.invoice_id,l.id,l.product_id,l.description,l.quantity,l.unit_price,l.gst_rate;
revoke all on public.sales_invoice_return_progress from public,anon;
grant select on public.sales_invoice_return_progress to authenticated;

create or replace function public.prevent_invoice_void_with_credit_notes()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.status='void' and old.status is distinct from 'void'
    and exists(select 1 from public.sales_credit_notes n where n.invoice_id=old.id and n.status<>'void') then
    raise exception 'Void or delete the linked credit notes before voiding this invoice';
  end if;
  return new;
end; $$;
create trigger invoice_credit_note_void_guard before update on public.sales_invoices
for each row execute function public.prevent_invoice_void_with_credit_notes();

create or replace function public.prevent_receipt_above_net_invoice()
returns trigger language plpgsql set search_path=public as $$
declare posted_credits numeric(18,2);
begin
  if new.amount_paid>old.amount_paid then
    select coalesce(sum(n.total),0) into posted_credits from public.sales_credit_notes n where n.invoice_id=old.id and n.status='posted';
    if new.amount_paid>old.total-posted_credits then raise exception 'Receipt exceeds invoice balance after credit notes'; end if;
  end if;
  return new;
end; $$;
create trigger invoice_net_receipt_guard before update on public.sales_invoices
for each row execute function public.prevent_receipt_above_net_invoice();

create or replace function public.create_sales_credit_note(target_invoice uuid,target_reason text,return_lines jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare inv public.sales_invoices%rowtype; new_note uuid; requested_count integer; valid_count integer;
begin
  select * into inv from public.sales_invoices where id=target_invoice and status in ('posted','paid') for update;
  if inv.id is null or not public.has_company_permission(inv.company_id,'sales') then raise exception 'Posted invoice not found or sales access denied'; end if;
  if nullif(trim(target_reason),'') is null or length(trim(target_reason))<3 then raise exception 'Return reason is required'; end if;
  if jsonb_typeof(return_lines)<>'array' or jsonb_array_length(return_lines)=0 then raise exception 'Select at least one quantity to return'; end if;
  if exists(select 1 from jsonb_array_elements(return_lines) x group by x->>'line_id' having count(*)>1) then raise exception 'An invoice line cannot be submitted twice'; end if;
  perform 1 from public.sales_invoice_lines where invoice_id=inv.id for update;
  requested_count:=jsonb_array_length(return_lines);
  select count(*) into valid_count from jsonb_array_elements(return_lines) x
  join public.sales_invoice_return_progress p on p.invoice_line_id=(x->>'line_id')::uuid and p.invoice_id=inv.id
  where (x->>'quantity')::numeric>0 and (x->>'quantity')::numeric<=p.remaining_quantity;
  if valid_count<>requested_count then raise exception 'Return contains an invalid line or quantity above the remaining balance'; end if;
  insert into public.sales_credit_notes(company_id,branch_id,customer_id,invoice_id,credit_date,reason,created_by)
  values(inv.company_id,inv.branch_id,inv.customer_id,inv.id,current_date,trim(target_reason),auth.uid()) returning id into new_note;
  insert into public.sales_credit_note_lines(credit_note_id,invoice_line_id,product_id,description,quantity,unit_price,gst_rate)
  select new_note,l.id,l.product_id,l.description,(x->>'quantity')::numeric,l.unit_price,l.gst_rate
  from jsonb_array_elements(return_lines) x join public.sales_invoice_lines l on l.id=(x->>'line_id')::uuid where l.invoice_id=inv.id;
  return new_note;
end; $$;

create or replace function public.post_sales_credit_note(target_note uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare n public.sales_credit_notes%rowtype; sub numeric(18,2); tax numeric(18,2); grand numeric(18,2); cogs numeric(18,2);
  ar uuid; sales uuid; gst uuid; inventory uuid; cogs_account uuid; new_journal uuid; target_warehouse uuid; line record;
begin
  select * into n from public.sales_credit_notes where id=target_note and status='draft' for update;
  if n.id is null or not public.has_company_permission(n.company_id,'sales') then raise exception 'Credit-note draft not found or sales access denied'; end if;
  perform 1 from public.sales_invoice_lines where invoice_id=n.invoice_id for update;
  if exists(select 1 from public.sales_credit_note_lines nl join public.sales_invoice_return_progress p on p.invoice_line_id=nl.invoice_line_id
    where nl.credit_note_id=n.id and p.returned_quantity>p.sold_quantity) then raise exception 'Returned quantity exceeds the original invoice'; end if;
  select coalesce(sum(subtotal),0),coalesce(sum(gst_amount),0),coalesce(sum(total),0) into sub,tax,grand from public.sales_credit_note_lines where credit_note_id=n.id;
  if grand<=0 then raise exception 'Credit note requires at least one positive line'; end if;
  select id into ar from public.accounts where company_id=n.company_id and code='1100';
  select id into sales from public.accounts where company_id=n.company_id and code='4000';
  select id into gst from public.accounts where company_id=n.company_id and code='2100';
  select id into inventory from public.accounts where company_id=n.company_id and code='1200';
  select id into cogs_account from public.accounts where company_id=n.company_id and code='5000';
  select coalesce(sum(nl.quantity*coalesce((select sum(m.quantity*m.unit_cost)/nullif(sum(m.quantity),0) from public.stock_movements m where m.source_type='sales_invoice' and m.source_id=n.invoice_id and m.product_id=nl.product_id and m.movement_type='sale'),0)),0)
    into cogs from public.sales_credit_note_lines nl join public.products p on p.id=nl.product_id where nl.credit_note_id=n.id and not p.is_service;
  if ar is null or sales is null or (tax>0 and gst is null) or (cogs>0 and (inventory is null or cogs_account is null)) then raise exception 'Required system accounts are missing'; end if;
  insert into public.journal_entries(company_id,branch_id,entry_date,reference,description,created_by)
  values(n.company_id,n.branch_id,n.credit_date,'CN-'||lpad(n.credit_number::text,6,'0'),'Sales return: '||n.reason,auth.uid()) returning id into new_journal;
  insert into public.journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,sales,'Sales return',sub,0),(new_journal,ar,'Customer credit',0,grand);
  if tax>0 then insert into public.journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,gst,'Output GST reversal',tax,0); end if;
  if cogs>0 then insert into public.journal_lines(entry_id,account_id,description,debit,credit) values(new_journal,inventory,'Returned inventory',cogs,0),(new_journal,cogs_account,'COGS reversal',0,cogs); end if;
  perform set_config('cloudledger.posting_permission','sales',true);
  perform public.post_journal(new_journal);
  select id into target_warehouse from public.warehouses where company_id=n.company_id and branch_id=n.branch_id and active order by created_at limit 1;
  for line in select nl.product_id,nl.quantity,p.is_service,
      coalesce((select sum(m.quantity*m.unit_cost)/nullif(sum(m.quantity),0) from public.stock_movements m where m.source_type='sales_invoice' and m.source_id=n.invoice_id and m.product_id=nl.product_id and m.movement_type='sale'),0) unit_cost
    from public.sales_credit_note_lines nl join public.products p on p.id=nl.product_id where nl.credit_note_id=n.id loop
    if not line.is_service then
      if target_warehouse is null then raise exception 'Branch warehouse is missing'; end if;
      insert into public.stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,reference,created_by)
      values(n.company_id,target_warehouse,line.product_id,'return_in',n.credit_date,line.quantity,line.unit_cost,'sales_credit_note',n.id,'INV-'||n.invoice_id,auth.uid());
    end if;
  end loop;
  perform set_config('cloudledger.allow_credit_note_transition','on',true);
  update public.sales_credit_notes set subtotal=sub,gst_total=tax,total=grand,status='posted',journal_entry_id=new_journal,posted_at=now() where id=n.id;
  return new_journal;
end; $$;

create or replace function public.void_sales_credit_note(target_note uuid,target_reason text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare n public.sales_credit_notes%rowtype; reversal uuid; line record;
begin
  select * into n from public.sales_credit_notes where id=target_note and status='posted' for update;
  if n.id is null or not public.has_company_permission(n.company_id,'sales') then raise exception 'Posted credit note not found or sales access denied'; end if;
  for line in select warehouse_id,product_id,quantity,unit_cost from public.stock_movements where source_type='sales_credit_note' and source_id=n.id and movement_type='return_in' loop
    insert into public.stock_movements(company_id,warehouse_id,product_id,movement_type,movement_date,quantity,unit_cost,source_type,source_id,reference,created_by)
    values(n.company_id,line.warehouse_id,line.product_id,'return_out',current_date,line.quantity,line.unit_cost,'sales_credit_note_void',n.id,target_reason,auth.uid());
  end loop;
  perform set_config('cloudledger.posting_permission','sales',true);
  reversal:=public.create_journal_reversal(n.journal_entry_id,target_reason);
  perform set_config('cloudledger.allow_credit_note_transition','on',true);
  update public.sales_credit_notes set status='void' where id=n.id;
  return reversal;
end; $$;

create or replace function public.get_receivable_aging(target_company uuid,as_of date default current_date)
returns table(contact_name text,current_amount numeric,days_1_30 numeric,days_31_60 numeric,days_61_90 numeric,days_over_90 numeric,total_due numeric)
language plpgsql stable security definer set search_path=public as $$
begin
  if as_of is null then raise exception 'As-of date is required'; end if;
  if not public.is_company_member(target_company) then raise exception 'Access denied'; end if;
  return query with document_balances as (
    select i.customer_id,i.due_date,greatest(i.total
      -coalesce((select sum(p.amount) from public.payments p where p.sales_invoice_id=i.id and p.status='posted' and p.direction='receipt' and p.payment_date<=as_of),0)
      -coalesce((select sum(n.total) from public.sales_credit_notes n where n.invoice_id=i.id and n.status='posted' and n.credit_date<=as_of),0),0)::numeric balance
    from public.sales_invoices i where i.company_id=target_company and i.invoice_date<=as_of and i.status in ('posted','paid')
  )
  select c.name,coalesce(sum(d.balance) filter(where as_of-d.due_date<=0),0),coalesce(sum(d.balance) filter(where as_of-d.due_date between 1 and 30),0),
    coalesce(sum(d.balance) filter(where as_of-d.due_date between 31 and 60),0),coalesce(sum(d.balance) filter(where as_of-d.due_date between 61 and 90),0),
    coalesce(sum(d.balance) filter(where as_of-d.due_date>90),0),sum(d.balance)
  from document_balances d join public.contacts c on c.id=d.customer_id and c.company_id=target_company where d.balance>0 group by c.id,c.name order by c.name;
end; $$;

create trigger sales_credit_note_audit after insert or update or delete on public.sales_credit_notes for each row execute function public.write_audit_log();
revoke all on function public.create_sales_credit_note(uuid,text,jsonb) from public,anon;
revoke all on function public.post_sales_credit_note(uuid) from public,anon;
revoke all on function public.void_sales_credit_note(uuid,text) from public,anon;
grant execute on function public.create_sales_credit_note(uuid,text,jsonb) to authenticated;
grant execute on function public.post_sales_credit_note(uuid) to authenticated;
grant execute on function public.void_sales_credit_note(uuid,text) to authenticated;
commit;
