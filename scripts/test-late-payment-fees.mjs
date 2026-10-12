// Optional prerequisite: npm install --no-save @electric-sql/pglite
import {PGlite} from '@electric-sql/pglite';import {readFileSync} from 'node:fs';import assert from 'node:assert/strict';
const db=new PGlite();await db.exec(`create role anon;create role authenticated;create schema auth;
create function auth.uid() returns uuid language sql as $$select '00000000-0000-0000-0000-000000000001'::uuid$$;
create function has_company_permission(uuid,text) returns boolean language sql as $$select coalesce(current_setting('test.allow',true),'yes')='yes'$$;
create table sales_invoices(id uuid default gen_random_uuid(),company_id uuid,branch_id uuid,customer_id uuid,invoice_number bigint generated always as identity,invoice_date date,due_date date,reference text,notes text,created_by uuid,status text default 'draft',total numeric default 0,amount_paid numeric default 0);
create table sales_invoice_lines(invoice_id uuid,description text,quantity numeric,unit_price numeric,gst_rate numeric);
create function post_sales_invoice(target uuid) returns void language plpgsql as $$begin if current_setting('test.fail',true)='yes' then raise exception 'posting failed';end if;update sales_invoices set status='posted' where id=target;end$$;`);
await db.exec(readFileSync('supabase/migrations/0032_late_payment_fees.sql','utf8'));
const c='00000000-0000-0000-0000-000000000002';const source=(await db.query("insert into sales_invoices(company_id,invoice_date,due_date,status,total) values($1,'2026-01-01','2026-01-10','posted',1000) returning id",[c])).rows[0].id;
const fee=(amount='100',date='2026-01-11',post=false)=>db.query('select create_late_payment_fee($1,$2,0,$3,$4) id',[source,amount,date,post]);
await assert.rejects(fee('100','2026-01-10'));await assert.rejects(fee('NaN'));await assert.rejects(fee('1.001'));
await db.exec("set test.allow='no'");await assert.rejects(fee());await db.exec("set test.allow='yes';set test.fail='yes'");await assert.rejects(fee('100','2026-01-11',true));assert.equal((await db.query('select count(*)::int n from sales_invoices')).rows[0].n,1);
await db.exec("set test.fail='no'");await fee();await assert.rejects(fee());assert.equal(Number((await db.query('select total from sales_invoices where id=$1',[source])).rows[0].total),1000);
await db.query('update sales_invoices set amount_paid=total where id=$1',[source]);await assert.rejects(fee('100','2026-01-12'));await db.close();console.log('Fee eligibility, duplicate prevention, permission, amount and atomic rollback checks passed with mocked invoice posting.');
