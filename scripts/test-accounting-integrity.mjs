import {PGlite} from '@electric-sql/pglite';
import {readFileSync,readdirSync} from 'node:fs';
import assert from 'node:assert/strict';
// End-to-end checks on the full migration chain: balance sheet, books lock, numbering, chart of accounts, backup, anon access.
const db=new PGlite();
await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb default '{}');create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('test.uid',true),'')::uuid$$;create function auth.jwt() returns jsonb language sql stable as $$select '{}'::jsonb$$;create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text,metadata jsonb,owner uuid,created_at timestamptz default now(),updated_at timestamptz default now());`);
for(const f of readdirSync('supabase/migrations').filter(f=>f.endsWith('.sql')).sort()) await db.exec(readFileSync('supabase/migrations/'+f,'utf8').replace('create extension if not exists pgcrypto;',''));
const u1='00000000-0000-0000-0000-000000000001',u2='00000000-0000-0000-0000-000000000002';
for(const [u,e] of [[u1,'a@x.test'],[u2,'b@x.test']]) await db.query('insert into auth.users(id,email) values($1,$2)',[u,e]);
await db.exec('grant usage on schema public,auth to authenticated;grant all on all tables in schema public to authenticated;grant usage,select on all sequences in schema public to authenticated;set role authenticated');
const as=async u=>db.exec(`set test.uid='${u}'`);
const q=async(sql,p=[])=>(await db.query(sql,p)).rows;
const setup=async(name)=>{
  const c=(await q('select create_company($1) id',[name]))[0].id;
  const b=(await q('select id from branches where company_id=$1 limit 1',[c]))[0].id;
  const wh=(await q('select id from warehouses where company_id=$1 limit 1',[c]))[0].id;
  const cust=(await q("insert into contacts(company_id,name,kind) values($1,'Cust','customer') returning id",[c]))[0].id;
  const supp=(await q("insert into contacts(company_id,name,kind) values($1,'Supp','supplier') returning id",[c]))[0].id;
  const prod=(await q("insert into products(company_id,sku,name,unit,sale_price,purchase_price,gst_rate) values($1,'P1','Camera','each',250,100,18) returning id",[c]))[0].id;
  return {c,b,wh,cust,supp,prod};
};
const bill=async(s,date)=>{const id=(await q("insert into purchase_bills(company_id,branch_id,supplier_id,bill_date,due_date,created_by,warehouse_id) values($1,$2,$3,$4,$4,$5,$6) returning id",[s.c,s.b,s.supp,date,u1,s.wh]))[0].id;await q("insert into purchase_bill_lines(bill_id,product_id,description,quantity,unit_price,gst_rate) values($1,$2,'Camera',100,100,18)",[id,s.prod]);await q('select post_purchase_bill($1)',[id]);return id;};
const invoice=async(s,date,qty=4)=>{const id=(await q("insert into sales_invoices(company_id,branch_id,customer_id,invoice_date,due_date,created_by,warehouse_id) values($1,$2,$3,$4,$4,$5,$6) returning id",[s.c,s.b,s.cust,date,u1,s.wh]))[0].id;await q("insert into sales_invoice_lines(invoice_id,product_id,description,quantity,unit_price,gst_rate) values($1,$2,'Camera',$3,250,18)",[id,s.prod,qty]);await q('select post_sales_invoice($1)',[id]);return id;};

await as(u1);
const A=await setup('Company A');
await as(u2);
const B=await setup('Company B');
await as(u1);

// --- chart of accounts: standard accounts plus the system accounts
const codes=(await q('select code from accounts where company_id=$1',[A.c])).map(r=>r.code);
assert.ok(codes.length>=45,'standard chart of accounts is seeded');
for(const code of ['1000','1100','1150','1200','2000','2100','3000','4000','5000','6000','1400','1410','3100','3200','6010','6020','6110','6120']) assert.ok(codes.includes(code),'account '+code);
const dup=(await q('select count(*) n from (select code from accounts where company_id=$1 group by code having count(*)>1) d',[A.c]))[0].n;
assert.equal(Number(dup),0);

// --- numbering is per company
await bill(A,'2026-10-01');
await as(u2);await bill(B,'2026-10-01');await as(u1);
const a1=await invoice(A,'2026-10-05'),a2=await invoice(A,'2026-10-06');
await as(u2);const b1=await invoice(B,'2026-10-05');await as(u1);
const num=async id=>Number((await q('select invoice_number n from sales_invoices where id=$1',[id]))[0].n);
assert.deepEqual([await num(a1),await num(a2)],[1,2],'company A numbers start at 1');
await as(u2);assert.equal(await num(b1),1,'company B also starts at 1');await as(u1);
assert.equal(Number((await q("select entry_number n from journal_entries where company_id=$1 order by entry_number limit 1",[A.c]))[0].n),1);

// --- balance sheet balances (assets = liabilities + equity incl. earnings)
const sheet=async(asOf)=>{const r=await q('select * from get_balance_sheet($1,$2)',[A.c,asOf]);const sum=c=>r.filter(x=>x.category===c).reduce((n,x)=>n+Number(x.amount),0);return {A:sum('asset'),L:sum('liability'),E:sum('equity'),rows:r};};
let s=await sheet('2026-12-31');
assert.ok(Math.abs(s.A-s.L-s.E)<0.005,`balance sheet balances: ${s.A} vs ${s.L}+${s.E}`);
assert.ok(s.rows.some(r=>r.account_code==='CYE'&&Number(r.amount)>0),'current year earnings shown');
// earnings from a previous financial year move to retained earnings (FY starts in July)
await q("insert into journal_entries(company_id,branch_id,entry_date,reference,created_by) values($1,$2,'2025-08-10','PRIOR',$3)",[A.c,A.b,u1]);
const pe=(await q("select id from journal_entries where reference='PRIOR'"))[0].id;
await q("insert into journal_lines(entry_id,account_id,debit,credit) select $1::uuid,(select id from accounts where company_id=$2 and code='1000'),700,0 union all select $1::uuid,(select id from accounts where company_id=$2 and code='4000'),0,700",[pe,A.c]);
await q('select post_journal($1)',[pe]);
s=await sheet('2026-12-31');
assert.ok(Math.abs(s.A-s.L-s.E)<0.005,'still balanced with prior-year profit');
assert.equal(Number(s.rows.find(r=>r.account_code==='RE').amount),700,'prior-year profit is retained earnings');

// --- books lock
await assert.rejects(q('select set_books_lock($1,$2)',[A.c,'2999-01-01']),/future/);
await q('select set_books_lock($1,$2)',[A.c,'2026-10-10']);
await assert.rejects(invoice(A,'2026-10-08'),/books are locked through 10 Oct 2026/);
await assert.rejects(q('select void_sales_invoice($1)',[a1]),/books are locked/);
const ok=await invoice(A,'2026-10-12');assert.ok(ok);
await q('select set_books_lock($1,null)',[A.c]);
assert.ok(await invoice(A,'2026-10-08'),'allowed after unlock');
await as(u2);await assert.rejects(q('select set_books_lock($1,$2)',[A.c,'2026-01-01']),/owner or admin/);await as(u1);

// --- GST summary matches the posted invoices and bills
const gst=await q('select * from get_gst_summary($1,$2,$3)',[A.c,'2026-01-01','2026-12-31']);
const expOut=Number((await q("select coalesce(sum(gst_total),0) t from sales_invoices where company_id=$1 and status not in ('draft','void')",[A.c]))[0].t);
const expIn=Number((await q("select coalesce(sum(gst_total),0) t from purchase_bills where company_id=$1 and status not in ('draft','void')",[A.c]))[0].t);
assert.ok(expOut>0&&expIn>0);
assert.equal(gst.reduce((n,r)=>n+Number(r.output_gst),0),expOut);assert.equal(gst.reduce((n,r)=>n+Number(r.input_gst),0),expIn);
assert.equal(gst.reduce((n,r)=>n+Number(r.net_gst_payable),0),expOut-expIn);
await as(u2);await assert.rejects(q('select * from get_gst_summary($1,$2,$3)',[A.c,'2026-01-01','2026-12-31']),/Access denied/);await as(u1);

// --- backup export
const dump=(await q('select export_company_data($1) d',[A.c]))[0].d;
assert.equal(dump.format,'cloudledger-backup-v1');
assert.ok(dump.sales_invoices.length>=4&&dump.sales_invoice_lines.length>=4&&dump.journal_lines.length>0&&dump.accounts.length>=45);
assert.ok(dump.sales_invoices.every(r=>r.company_id===A.c),'export never includes another company');
await as(u2);await assert.rejects(q('select export_company_data($1)',[A.c]),/owner or admin/);await as(u1);

// --- anonymous (signed-out) users cannot execute database functions
await db.exec('reset role');
const open=await q("select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prokind='f' and has_function_privilege('anon',p.oid,'execute')");
assert.deepEqual(open,[],'anon has no function access');
console.log('Accounting integrity checks passed: balance sheet, books lock, numbering, chart of accounts, backup, anon access.');
