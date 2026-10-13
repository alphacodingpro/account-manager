begin;
-- Capture physical-goods drafts without touching stock or the general ledger.
create table public.goods_document_drafts (
 id uuid primary key default gen_random_uuid(),company_id uuid not null references companies(id),kind text not null check(kind in ('delivery','receipt')),document_number bigint generated always as identity,document_date date not null,contact_id uuid not null references contacts(id),warehouse_id uuid not null references warehouses(id),reference text,notes text,items jsonb not null,created_by uuid not null default auth.uid() references auth.users(id),created_at timestamptz not null default now(),check(jsonb_typeof(items)='array' and jsonb_array_length(items)>0)
);
alter table public.goods_document_drafts enable row level security;
create policy "goods draft permission" on public.goods_document_drafts for all using(has_company_permission(company_id,case when kind='delivery' then 'sales' else 'purchases' end)) with check(has_company_permission(company_id,case when kind='delivery' then 'sales' else 'purchases' end));
create function public.validate_goods_draft() returns trigger language plpgsql security invoker set search_path=public as $$
declare item jsonb; quantity numeric; seen uuid[]:='{}'; product uuid;
begin
 if tg_op='UPDATE' and (new.company_id<>old.company_id or new.kind<>old.kind or new.created_by<>old.created_by or new.id<>old.id or new.document_number<>old.document_number) then raise exception 'Document identity immutable';end if;
 if not exists(select 1 from contacts where id=new.contact_id and company_id=new.company_id and active and (kind='both' or kind=case when new.kind='delivery' then 'customer' else 'supplier' end)) then raise exception 'Invalid document contact';end if;
 if not exists(select 1 from warehouses where id=new.warehouse_id and company_id=new.company_id and active) then raise exception 'Invalid company warehouse';end if;
 if jsonb_typeof(new.items)<>'array' or jsonb_array_length(new.items)=0 then raise exception 'At least one goods line required';end if;
 for item in select value from jsonb_array_elements(new.items) loop
  product:=(item->>'product_id')::uuid;quantity:=(item->>'quantity')::numeric;
  if quantity is null or quantity::text in ('NaN','Infinity','-Infinity') or quantity<=0 or quantity<>round(quantity,3) or quantity>=1000000000000000 or nullif(trim(item->>'description'),'') is null then raise exception 'Invalid goods line';end if;
  if product=any(seen) then raise exception 'Combine duplicate product quantities';end if;seen:=array_append(seen,product);
  if not exists(select 1 from products where id=product and company_id=new.company_id and active and not is_service) then raise exception 'Invalid stock product';end if;
 end loop;return new;
end $$;
create trigger goods_draft_validate before insert or update on public.goods_document_drafts for each row execute function public.validate_goods_draft();
create trigger goods_draft_audit after insert or update or delete on public.goods_document_drafts for each row execute function public.write_audit_log();
commit;
