// Optional isolated test prerequisite: npm install --no-save @electric-sql/pglite
import {PGlite} from '@electric-sql/pglite';
import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const db=new PGlite();
await db.exec(`create role anon; create role authenticated; create schema auth;
create function auth.uid() returns uuid language sql as $$select '00000000-0000-0000-0000-000000000001'::uuid$$;
create function has_company_permission(uuid,text) returns boolean language sql as $$select coalesce(current_setting('test.allowed',true),'yes')='yes'$$;
create table branches(id uuid,company_id uuid,active boolean);create table accounts(id uuid,company_id uuid,active boolean,type text,code text);create table bank_accounts(company_id uuid,ledger_account_id uuid,active boolean);
create table journal_entries(id uuid default gen_random_uuid(),company_id uuid,branch_id uuid,entry_date date,reference text,description text,status text default 'draft',created_by uuid);
create table journal_lines(entry_id uuid,account_id uuid,description text,debit numeric,credit numeric);
create function post_journal(uuid) returns void language plpgsql as $$begin if current_setting('test.fail',true)='yes' then raise exception 'posting failed';end if;end$$;`);

await db.exec(readFileSync('supabase/migrations/0030_expense_claims.sql','utf8'));
const c='00000000-0000-0000-0000-000000000002', a='00000000-0000-0000-0000-000000000003', b='00000000-0000-0000-0000-000000000004';
await db.query("insert into accounts values($1,$3,true,'expense','6000'),($2,$3,true,'liability','2250')",[a,b,c]);
const save=(id=null,amount='100.50',post=false)=>db.query('select save_expense_claim($1,$2,$3,$4,$5,$6,current_date,null,$7,$8) id',[c,'Employee','Travel',a,b,amount,id,post]);
const id=(await save()).rows[0].id;
assert.equal((await db.query('select sum(debit-credit)::text balance from journal_lines')).rows[0].balance,'0.00');
await save(id,'200');assert.equal((await db.query('select count(*)::int n from journal_lines')).rows[0].n,2);
await db.exec("set test.fail='yes'");await assert.rejects(save(id,'300',true));assert.equal(Number((await db.query('select debit from journal_lines where debit>0')).rows[0].debit),200);
await db.exec("set test.fail='no'");await db.query("update journal_entries set status='posted' where id=$1",[id]);await assert.rejects(save(id));
await assert.rejects(save(null,'NaN'));await assert.rejects(save(null,'1.001'));
await db.exec("set test.allowed='no'");await assert.rejects(save());
await db.close();console.log('Claims draft replacement, balance, immutability, permission and rollback checks passed with mocked posting.');
