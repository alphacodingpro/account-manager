import {PGlite} from '@electric-sql/pglite';
import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const db=new PGlite();
await db.exec(`create role anon;create role authenticated;create schema auth;
create function auth.uid() returns uuid language sql as $$select '00000000-0000-0000-0000-000000000001'::uuid$$;
create function has_company_permission(uuid,text) returns boolean language sql as $$select $1='00000000-0000-0000-0000-000000000002'::uuid and $2='accounting' and coalesce(current_setting('test.allowed',true),'yes')<>'no'$$;
create table journal_entries(id uuid primary key default gen_random_uuid(),company_id uuid,branch_id uuid,entry_date date default current_date,entry_number bigint generated always as identity,reference text,description text,reversal_of uuid,status text default 'draft',created_by uuid);
create table journal_lines(entry_id uuid,account_id uuid,description text,debit numeric,credit numeric);
create function post_journal(uuid) returns void language plpgsql as $$begin
 if (select count(*) from journal_lines where entry_id=$1)<2 or (select coalesce(sum(debit),0) from journal_lines where entry_id=$1)<=0 or (select sum(debit-credit) from journal_lines where entry_id=$1)<>0 then raise exception 'Unbalanced journal';end if;
 update journal_entries set status='posted' where id=$1;end$$;`);
const tables=['sales_invoices','purchase_bills','payroll_runs','payments','sales_credit_notes','purchase_debit_notes'];
for(const table of tables)await db.exec(`create table ${table}(journal_entry_id uuid);`);
const guards=readFileSync('supabase/migrations/0007_safe_record_management.sql','utf8');await db.exec(guards.slice(guards.indexOf('create or replace function public.protect_posted_journal'),guards.indexOf('create or replace function public.create_journal_reversal')));
await db.exec('create trigger immutable before update or delete on journal_entries for each row execute function protect_posted_journal()');
const original=readFileSync('supabase/migrations/0013_sales_role_permissions.sql','utf8');await db.exec(original.slice(original.indexOf('create or replace function public.create_journal_reversal'),original.indexOf('create or replace function public.void_sales_invoice')));
await db.exec('create function reverse_inventory_writeoff(uuid) returns uuid language sql as $$select $1$$');
await db.exec(readFileSync('supabase/migrations/0044_manual_reversal_source_guards.sql','utf8'));
const c='00000000-0000-0000-0000-000000000002',other='00000000-0000-0000-0000-000000000003';
async function seed(company=c){await db.exec('reset role');const id=(await db.query("insert into journal_entries(company_id,status) values($1,'posted') returning id",[company])).rows[0].id;await db.query('insert into journal_lines(entry_id,account_id,debit,credit) values($1,$2,118,0),($1,$2,0,100),($1,$2,0,18)',[id,c]);await db.exec('set role authenticated');return id;}
await db.exec('grant usage on schema public,auth to authenticated;grant select on journal_entries,journal_lines to authenticated;set role authenticated');
const reverse=id=>db.query('select reverse_manual_journal($1,$2) id',[id,'Correction']);
const count=async()=>Number((await db.query('select count(*) n from journal_entries')).rows[0].n);
for(const table of tables){const id=await seed();await db.exec('reset role');await db.query(`insert into ${table} values($1)`,[id]);await db.exec('set role authenticated');const before=await count();await assert.rejects(reverse(id),/source document/);assert.equal(await count(),before);assert.equal((await db.query('select status from journal_entries where id=$1',[id])).rows[0].status,'posted');}
const foreign=await seed(other);await assert.rejects(reverse(foreign),/access denied/);
const manual=await seed();await db.exec("set test.allowed='no'");await assert.rejects(reverse(manual),/access denied/);await db.exec("set test.allowed='yes'");
await assert.rejects(db.query('select create_journal_reversal($1,$2)',[manual,'Bypass']),/permission denied/);
const reversal=(await reverse(manual)).rows[0].id;assert.equal((await db.query('select status from journal_entries where id=$1',[manual])).rows[0].status,'reversed');assert.equal(Number((await db.query('select sum(debit-credit) balance from journal_lines where entry_id=$1',[reversal])).rows[0].balance),0);
const normalize=rows=>rows.map(r=>[Number(r.debit),Number(r.credit)]).sort((a,b)=>a[0]-b[0]||a[1]-b[1]);assert.deepEqual(normalize((await db.query('select debit,credit from journal_lines where entry_id=$1',[reversal])).rows),normalize((await db.query('select credit as debit,debit as credit from journal_lines where entry_id=$1',[manual])).rows));
await assert.rejects(reverse(reversal),/cannot be reversed again/);await assert.rejects(reverse(manual),/not found/);
// Internal source RPCs still execute the private helper under their definer.
const source=await seed();await db.exec('reset role');await db.exec(`create function test_source_void(uuid) returns uuid language sql security definer set search_path=public as $$select create_journal_reversal($1,'Source void')$$;grant execute on function test_source_void(uuid) to authenticated;`);await db.exec('set role authenticated');await db.query('select test_source_void($1)',[source]);
await db.close();console.log('All six source journal guards, cross-company/permission denial, private helper protection, balanced manual reversal, repeat/reversal-of-reversal rejection and internal source RPC compatibility passed.');
