begin;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('claim-receipts','claim-receipts',false,5242880,array['application/pdf','image/jpeg','image/png','image/webp']) on conflict(id) do nothing;
create function public.claim_receipt_access(object_name text,write_access boolean) returns boolean language sql stable security invoker set search_path=public as $$
 select exists(select 1 from journal_entries e where e.id=case when split_part(object_name,'/',2)~'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(object_name,'/',2)::uuid else null end and e.company_id::text=split_part(object_name,'/',1) and left(e.description,16)='[Expense claim] ' and has_company_permission(e.company_id,'accounting') and (not write_access or e.status='draft'));
$$;
create policy "claim receipt read" on storage.objects for select to authenticated using(bucket_id='claim-receipts' and claim_receipt_access(name,false));
create policy "claim receipt upload" on storage.objects for insert to authenticated with check(bucket_id='claim-receipts' and claim_receipt_access(name,true));
create policy "claim receipt delete" on storage.objects for delete to authenticated using(bucket_id='claim-receipts' and claim_receipt_access(name,true));
create table public.claim_attachments(id uuid primary key default gen_random_uuid(),company_id uuid not null references companies(id),entry_id uuid not null references journal_entries(id) on delete cascade,file_name text not null,storage_path text not null unique,mime_type text not null check(mime_type in ('application/pdf','image/jpeg','image/png','image/webp')),file_size bigint not null check(file_size>0 and file_size<=5242880),uploaded_by uuid not null default auth.uid() references auth.users(id),created_at timestamptz not null default now());
alter table public.claim_attachments enable row level security;
create policy "claim attachment read" on public.claim_attachments for select using(has_company_permission(company_id,'accounting') and claim_receipt_access(storage_path,false));
create policy "claim attachment insert" on public.claim_attachments for insert with check(has_company_permission(company_id,'accounting') and uploaded_by=auth.uid() and company_id::text=split_part(storage_path,'/',1) and entry_id::text=split_part(storage_path,'/',2) and claim_receipt_access(storage_path,true));
create policy "claim attachment delete" on public.claim_attachments for delete using(has_company_permission(company_id,'accounting') and claim_receipt_access(storage_path,true));
create trigger claim_attachment_audit after insert or delete on public.claim_attachments for each row execute function write_audit_log();
-- Serialize receipt writes with approval/posting; posted receipts are immutable.
create function public.guard_claim_receipt_write() returns trigger language plpgsql security invoker set search_path=public as $$
declare target_path text; target_id uuid; claim_status text;
begin
 if TG_TABLE_SCHEMA='storage' then
  if coalesce(new.bucket_id,'')<>'claim-receipts' and coalesce(old.bucket_id,'')<>'claim-receipts' then return coalesce(new,old); end if;
  if TG_OP='UPDATE' and (new.bucket_id is distinct from old.bucket_id or new.name is distinct from old.name) then raise exception 'Receipt paths are immutable'; end if;
  target_path:=coalesce(new.name,old.name);
 else target_path:=coalesce(new.storage_path,old.storage_path); end if;
 if split_part(target_path,'/',2)!~'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'Invalid receipt path'; end if;
 target_id:=split_part(target_path,'/',2)::uuid;
 select status into claim_status from journal_entries where id=target_id for update;
 -- Parent deletion cascades metadata only; orphaned objects remain inaccessible.
 if claim_status is null and TG_TABLE_SCHEMA='public' and TG_OP='DELETE' then return old; end if;
 if claim_status is distinct from 'draft' or not claim_receipt_access(target_path,true) then raise exception 'Only accessible draft claims can change receipts'; end if;
 return coalesce(new,old);
end; $$;
create trigger claim_receipt_write_guard before insert or update or delete on storage.objects for each row execute function guard_claim_receipt_write();
create trigger claim_attachment_write_guard before insert or update or delete on claim_attachments for each row execute function guard_claim_receipt_write();
-- Object identity/existence is included: removal or replacement invalidates approval.
create or replace function public.expense_claim_fingerprint(target_entry uuid) returns text language sql stable security invoker set search_path=public as $$
 select md5((to_jsonb(e)-'status'-'posted_by'-'posted_at')::text||coalesce((select jsonb_agg(to_jsonb(l) order by l.id)::text from journal_lines l where l.entry_id=e.id),'[]')||coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('object', (select to_jsonb(o) from storage.objects o where o.bucket_id='claim-receipts' and o.name=a.storage_path)) order by a.id)::text from claim_attachments a where a.entry_id=e.id),'[]')) from journal_entries e where e.id=target_entry;
$$;
commit;
