// Optional isolated test prerequisite: npm install --no-save @electric-sql/pglite
import {PGlite} from '@electric-sql/pglite';
import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const db=new PGlite();
await db.exec(`create role anon; create role authenticated; create schema auth;
create function auth.uid() returns uuid language sql as $$select '00000000-0000-0000-0000-000000000001'::uuid$$;
create function has_company_permission(uuid,text) returns boolean language sql as $$select coalesce(current_setting('test.allowed',true),'yes')='yes'$$;
create table branches(id uuid,company_id uuid,active boolean);create table accounts(id uuid,company_id uuid,active boolean,type text,code text);create table bank_accounts(company_id uuid,ledger_account_id uuid,active boolean);
create table journal_entries(id uuid default gen_random_uuid(),company_id uuid,branch_id uuid,entry_date date,reference text,description text,entry_number bigint generated always as identity,status text default 'draft',created_by uuid);
create table journal_lines(entry_id uuid,account_id uuid,description text,debit numeric,credit numeric);
create function post_journal(uuid) returns void language plpgsql as $$begin if current_setting('test.fail',true)='yes' then raise exception 'posting failed';end if;end$$;`);


await db.exec(readFileSync('supabase/migrations/0030_expense_claims.sql','utf8'));
await db.exec(readFileSync('supabase/migrations/0031_expense_claim_settlement.sql','utf8'));
await db.exec(`create or replace function post_journal(target uuid) returns void language plpgsql as $$begin if current_setting('test.fail',true)='yes' then raise exception 'posting failed';end if;update journal_entries set status='posted' where id=target;end$$;`);
const c='00000000-0000-0000-0000-000000000002', a='00000000-0000-0000-0000-000000000003', b='00000000-0000-0000-0000-000000000004', cash='00000000-0000-0000-0000-000000000005';
await db.query("insert into accounts values($1,$3,true,'expense','6000'),($2,$3,true,'liability','2250'),($4,$3,true,'asset','1000')",[a,b,c,cash]);
const claim=(await db.query("select save_expense_claim($1,'Employee','Travel',$2,$3,100,current_date,null,null,true) id",[c,a,b])).rows[0].id;
const settle=(account=cash)=>db.query('select settle_expense_claim($1,$2,current_date) id',[claim,account]);
await assert.rejects(settle(a));await db.exec("set test.allowed='no'");await assert.rejects(settle());await db.exec("set test.allowed='yes';set test.fail='yes'");await assert.rejects(settle());assert.equal((await db.query('select count(*)::int n from journal_entries')).rows[0].n,1);
await db.exec("set test.fail='no'");const payment=(await settle()).rows[0].id;await assert.rejects(settle());
await assert.rejects(db.query("update journal_entries set status='reversed' where id=$1",[claim]));
assert.equal((await db.query('select sum(debit-credit)::text balance from journal_lines')).rows[0].balance,'0');
await db.query("update journal_entries set status='reversed' where id=$1",[payment]);await settle();
console.log('Reimbursement balance, duplicate protection, permission, rollback, reversal guard and repayment checks passed (mocked posting).');await db.close();
