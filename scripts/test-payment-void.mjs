import {PGlite} from '@electric-sql/pglite';
import {readFileSync,readdirSync} from 'node:fs';
import assert from 'node:assert/strict';
// Regression: posted receipts and supplier payments can be voided, restoring the document balance.
const db=new PGlite();
await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb default '{}');create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('test.uid',true),'')::uuid$$;create function auth.jwt() returns jsonb language sql stable as $$select '{}'::jsonb$$;create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text,metadata jsonb,owner uuid,created_at timestamptz default now(),updated_at timestamptz default now());`);
for(const f of readdirSync('supabase/migrations').filter(f=>f.endsWith('.sql')).sort()) await db.exec(readFileSync('supabase/migrations/'+f,'utf8').replace('create extension if not exists pgcrypto;',''));
const u='00000000-0000-0000-0000-000000000001';await db.query('insert into auth.users(id,email) values($1,$2)',[u,'o@x.test']);await db.exec(`set test.uid='${u}'`);
await db.exec('grant usage on schema public,auth to authenticated;grant all on all tables in schema public to authenticated;grant usage,select on all sequences in schema public to authenticated;set role authenticated');
const q=async(sql,p=[])=>(await db.query(sql,p)).rows;
const c=(await q("select create_company('Void test') id"))[0].id;
const b=(await q('select id from branches where company_id=$1 limit 1',[c]))[0].id;
const wh=(await q('select id from warehouses where company_id=$1 limit 1',[c]))[0].id;
const acct=async code=>(await q('select id from accounts where company_id=$1 and code=$2',[c,code]))[0].id;
const cust=(await q("insert into contacts(company_id,name,kind) values($1,'Cust','customer') returning id",[c]))[0].id;
const supp=(await q("insert into contacts(company_id,name,kind) values($1,'Supp','supplier') returning id",[c]))[0].id;
const prod=(await q("insert into products(company_id,sku,name,unit,sale_price,purchase_price,gst_rate) values($1,'P1','Camera','each',250,100,18) returning id",[c]))[0].id;
const bill=(await q("insert into purchase_bills(company_id,branch_id,supplier_id,bill_date,due_date,created_by,warehouse_id) values($1,$2,$3,'2026-10-01','2026-10-31',$4,$5) returning id",[c,b,supp,u,wh]))[0].id;
await q("insert into purchase_bill_lines(bill_id,product_id,description,quantity,unit_price,gst_rate) values($1,$2,'Camera',10,100,18)",[bill,prod]);await q('select post_purchase_bill($1)',[bill]);
const inv=(await q("insert into sales_invoices(company_id,branch_id,customer_id,invoice_date,due_date,created_by,warehouse_id) values($1,$2,$3,'2026-10-05','2026-11-04',$4,$5) returning id",[c,b,cust,u,wh]))[0].id;
await q("insert into sales_invoice_lines(invoice_id,product_id,description,quantity,unit_price,gst_rate) values($1,$2,'Camera',4,250,18)",[inv,prod]);await q('select post_sales_invoice($1)',[inv]);
const cash=await acct('1000');
const pay=async(dir,contact,amount,col,id)=>{const p=(await q(`insert into payments(company_id,branch_id,contact_id,cash_account_id,direction,payment_date,amount,created_by${col?','+col:''}) values($1,$2,$3,$4,$5,'2026-10-10',$6,$7${col?',$8':''}) returning id`,col?[c,b,contact,cash,dir,amount,u,id]:[c,b,contact,cash,dir,amount,u]))[0].id;await q('select post_payment($1)',[p]);return p;};
const ledger=async code=>Number((await q("select coalesce(sum(l.debit-l.credit),0) b from journal_lines l join journal_entries e on e.id=l.entry_id join accounts a on a.id=l.account_id where a.company_id=$1 and a.code=$2 and e.status in ('posted','reversed')",[c,code]))[0].b);
// receipt against a sales invoice
const arBefore=await ledger('1100');
const rcpt=await pay('receipt',cust,500,'sales_invoice_id',inv);
assert.equal((await q('select amount_paid from sales_invoices where id=$1',[inv]))[0].amount_paid,'500.00');
await q('select void_payment($1,$2)',[rcpt,'entered twice']);
assert.equal((await q('select status from payments where id=$1',[rcpt]))[0].status,'void');
assert.deepEqual((await q('select status,amount_paid from sales_invoices where id=$1',[inv]))[0],{status:'posted',amount_paid:'0.00'});
assert.equal(await ledger('1100'),arBefore,'receivable restored after voiding the receipt');
// supplier payment against a bill, then an unallocated advance
const sp=await pay('payment',supp,400,'purchase_bill_id',bill);
assert.equal((await q('select amount_paid,status from purchase_bills where id=$1',[bill]))[0].status,'part_paid');
await q('select void_payment($1,$2)',[sp,'wrong supplier']);
assert.deepEqual((await q('select status,amount_paid from purchase_bills where id=$1',[bill]))[0],{status:'posted',amount_paid:'0.00'});
const advance=await pay('receipt',cust,100,null,null);await q('select void_payment($1,$2)',[advance,'cancelled']);
assert.equal((await q('select status from payments where id=$1',[advance]))[0].status,'void');
// a voided payment cannot be edited, and a posted one cannot be edited directly
await assert.rejects(q("update payments set amount=1 where id=$1",[rcpt]),/immutable/);
const live=await pay('receipt',cust,50,'sales_invoice_id',inv);
await assert.rejects(q("update payments set amount=1 where id=$1",[live]),/immutable/);
// bill payment guard still works: a posted bill's total cannot be changed
await assert.rejects(q("update purchase_bills set total=1 where id=$1",[bill]),/immutable/);
const tb=await q('select * from get_trial_balance($1,null,$2)',[c,'2026-12-31']);
assert.equal(tb.reduce((n,x)=>n+Number(x.debit),0),tb.reduce((n,x)=>n+Number(x.credit),0),'trial balance stays balanced');
console.log('Payment void regression passed: receipts, supplier payments and advances can be reversed safely.');
