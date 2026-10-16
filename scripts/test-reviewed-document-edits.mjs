import {PGlite} from '@electric-sql/pglite';
import {readFileSync,readdirSync} from 'node:fs';
import assert from 'node:assert/strict';
const db=new PGlite();
await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb default '{}');create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('test.uid',true),'')::uuid$$;create function auth.jwt() returns jsonb language sql stable as $$select '{}'::jsonb$$;create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text,metadata jsonb,owner uuid,created_at timestamptz default now(),updated_at timestamptz default now());`);
for(const file of readdirSync('supabase/migrations').filter(f=>f.endsWith('.sql')).sort()){
 try{await db.exec(readFileSync(`supabase/migrations/${file}`,'utf8').replace('create extension if not exists pgcrypto;',''));}catch(e){throw new Error(`${file}: ${e.message}`);}
}
console.log('All repository migrations applied on a clean isolated PostgreSQL schema.');
const u='00000000-0000-0000-0000-000000000001';await db.query('insert into auth.users(id,email) values($1,$2)',[u,'owner@example.test']);await db.exec(`set test.uid='${u}'`);
await db.exec('grant usage on schema public,auth to authenticated;grant all on all tables in schema public to authenticated;grant usage,select on all sequences in schema public to authenticated;set role authenticated');
const c=(await db.query("select create_company('UI review test') id")).rows[0].id;
const b=(await db.query('select id from branches where company_id=$1 limit 1',[c])).rows[0].id;
const contact=(await db.query("insert into contacts(company_id,name,kind) values($1,'Review customer','both') returning id",[c])).rows[0].id;
const account=(await db.query("select id from accounts where company_id=$1 and code='6000'",[c])).rows[0].id;
const headerCols={quotations:['quotation_date','valid_until','notes'],sales_orders:['order_date','promised_date','customer_reference','notes'],purchase_orders:['order_date','expected_date','supplier_reference','notes'],sales_credit_notes:['credit_date','reason'],purchase_debit_notes:['debit_date','reason'],journal_entries:['entry_date','reference','description']};
const childInfo={quotations:['quotation_lines','quotation_id'],sales_orders:['sales_order_lines','sales_order_id'],purchase_orders:['purchase_order_lines','purchase_order_id'],sales_credit_notes:['sales_credit_note_lines','credit_note_id'],purchase_debit_notes:['purchase_debit_note_lines','debit_note_id'],journal_entries:['journal_lines','entry_id']};
const lineCols=kind=>kind==='journal_entries'?['id','description','debit','credit']:kind.includes('_notes')?['id','quantity']:['id','description','quantity','unit_price','gst_rate'];
const project=(row,keys)=>Object.fromEntries(keys.map(k=>[k,row[k]??null]));
const snapshot=async(kind,id)=>{const h=(await db.query(`select to_jsonb(t) data from ${kind} t where id=$1`,[id])).rows[0].data;const [table,parent]=childInfo[kind];const lines=(await db.query(`select to_jsonb(t) data from ${table} t where ${parent}=$1 order by id`,[id])).rows.map(r=>project(r.data,lineCols(kind)));return {header:project(h,headerCols[kind]),lines};};
const save=(kind,id,old,h=old.header,lines=old.lines,company=c)=>db.query('select update_reviewed_draft($1,$2,$3,$4,$5,$6,$7)',[company,kind,id,JSON.stringify(old.header),JSON.stringify(h),JSON.stringify(old.lines),JSON.stringify(lines)]);
for(const kind of ['quotations','sales_orders','purchase_orders','journal_entries']){
 const supplier=kind==='purchase_orders',journal=kind==='journal_entries',date=kind==='quotations'?'quotation_date':journal?'entry_date':'order_date';
 const id=(await db.query(`insert into ${kind}(company_id,branch_id,${journal?'reference':supplier?'supplier_id':'customer_id'},${date},created_by) values($1,$2,$3,'2026-10-16',$4) returning id`,[c,b,journal?'MANUAL':contact,u])).rows[0].id;
 const [table,parent]=childInfo[kind];
 if(journal){await db.query(`insert into ${table}(${parent},account_id,description,debit,credit) values($1,$2,'Line A',100,0),($1,$2,'Line B',0,100)`,[id,account]);}
 else {await db.query(`insert into ${table}(${parent},description,quantity,unit_price,gst_rate${supplier?',expense_account_id':''}) values($1,'Line A',2,100,18${supplier?',$2':''}),($1,'Line B',3,200,18${supplier?',$2':''})`,supplier?[id,account]:[id]);}
 const old=await snapshot(kind,id),updated=old.lines.map((l,i)=>({...l,...(journal?{description:`Reviewed ${i}`}:{quantity:4,description:`Reviewed ${i}`})}));
 await save(kind,id,old,old.header,updated);const after=await snapshot(kind,id);
 const revision=(await db.query("select user_id,old_values,new_values from audit_log where company_id=$1 and entity_type=$2 and entity_id=$3 and action='LINE_UPDATE' order by id desc",[c,kind,id])).rows;
 assert.equal(revision.length,2);for(const r of revision){assert.equal(r.user_id,u);assert.equal(r.old_values.line.description,old.lines.find(l=>l.id===r.old_values.line.id).description);assert.equal(r.new_values.line.description,updated.find(l=>l.id===r.new_values.line.id).description);}assert.equal(revision[0].new_values.line.id,revision[0].old_values.line.id);
 const countAudit=async()=>Number((await db.query("select count(*) n from audit_log where company_id=$1 and entity_type=$2 and entity_id=$3 and action like 'LINE_%'",[c,kind,id])).rows[0].n);
 const noOpCount=await countAudit();await save(kind,id,after);assert.equal(await countAudit(),noOpCount);assert.deepEqual(after.lines,updated);assert.deepEqual(after.lines.map(l=>l.id),old.lines.map(l=>l.id));
 await assert.rejects(save(kind,id,old),/changed/);
 await assert.rejects(save(kind,id,after,{...after.header,company_id:c}),/Invalid/);
 await assert.rejects(save(kind,id,after,after.header,[updated[0],updated[0]]),/Duplicate/);
 await assert.rejects(save(kind,id,after,after.header,updated.map(l=>({...l,quantity:-1}))),/Invalid/);
 assert.deepEqual(await snapshot(kind,id),after);
 // A failure on a later line must roll back earlier line and header updates.
 await db.exec('reset role');await db.exec(`create or replace function fail_review_line() returns trigger language plpgsql as $$begin if new.id='${after.lines[1].id}'::uuid then raise exception 'Second line rejected';end if;return new;end$$;create trigger test_fail_line before update on ${table} for each row execute function fail_review_line();set role authenticated`);
 const beforeFailure=await countAudit();await assert.rejects(save(kind,id,after,after.header,after.lines.map(l=>({...l,description:'Changed'}))),/Second line rejected|Invalid/);assert.deepEqual(await snapshot(kind,id),after);assert.equal(await countAudit(),beforeFailure);
 await db.exec(`reset role;drop trigger test_fail_line on ${table};set role authenticated`);
 const clone=(await db.query(`insert into ${kind}(company_id,branch_id,${journal?'reference':supplier?'supplier_id':'customer_id'},${date},created_by) values($1,$2,$3,'2026-10-16',$4) returning id`,[c,b,journal?'AUDIT DELETE':contact,u])).rows[0].id;
 const copyCols=journal?'account_id,description,debit,credit':`description,quantity,unit_price,gst_rate${supplier?',expense_account_id':''}`;
 await db.query(`insert into ${table}(${parent},${copyCols}) select $1,${copyCols} from ${table} where ${parent}=$2`,[clone,id]);await db.query(`delete from ${kind} where id=$1`,[clone]);
 const deleted=(await db.query("select old_values from audit_log where company_id=$1 and entity_type=$2 and entity_id=$3 and action='DOCUMENT_DELETE'",[c,kind,clone])).rows[0];assert.equal(deleted.old_values._lines.length,2);assert.ok(deleted.old_values._lines.every(l=>l.description.startsWith('Reviewed')));
 if(!journal){const fn=kind==='quotations'?'approve_sales_quotation':kind==='sales_orders'?'approve_sales_order':'approve_purchase_order';await db.query(`select ${fn}($1)`,[id]);await assert.rejects(save(kind,id,after),/Only an accessible draft/);const directCount=await countAudit();await assert.rejects(db.query(`update ${table} set quantity=quantity+1 where ${parent}=$1`,[id]),/immutable/);await assert.rejects(db.query(`delete from ${table} where ${parent}=$1`,[id]),/immutable/);assert.equal(await countAudit(),directCount);await assert.rejects(db.query(`delete from ${kind} where id=$1`,[id]));assert.equal(Number((await db.query("select count(*) n from audit_log where company_id=$1 and entity_type=$2 and entity_id=$3 and action='DOCUMENT_DELETE'",[c,kind,id])).rows[0].n),0);}
 console.log(`${kind}: editable lines, stable IDs, stale snapshot, invalid fields, rollback and immutable approval passed.`);
}
// Return editors retain source prices/identity and enforce original quantities.
for(const sales of [true,false]){
 const sourceKind=sales?'sales_invoices':'purchase_bills',kind=sales?'sales_credit_notes':'purchase_debit_notes',sourceLine=sales?'sales_invoice_lines':'purchase_bill_lines',sourceParent=sales?'invoice_id':'bill_id';
 const h={company_id:c,branch_id:b,[sales?'customer_id':'supplier_id']:contact,[sales?'invoice_date':'bill_date']:'2026-10-16',due_date:'2026-11-16'};
 const source=(await db.query(`select ${sales?'save_sales_invoice_draft':'save_purchase_bill_draft'}(null,$1,$2,true) id`,[JSON.stringify(h),JSON.stringify([{description:'Returned service',quantity:5,unit_price:100,gst_rate:18,...(!sales?{expense_account_id:account}:{})}])])).rows[0].id;
 const line=(await db.query(`select id from ${sourceLine} where ${sourceParent}=$1`,[source])).rows[0].id;
 const id=(await db.query(`select ${sales?'create_sales_credit_note':'create_purchase_debit_note'}($1,'Reviewed return',$2) id`,[source,JSON.stringify([{line_id:line,quantity:1}])])).rows[0].id;
 const old=await snapshot(kind,id);await save(kind,id,old,old.header,old.lines.map(l=>({...l,quantity:2})));
 const after=await snapshot(kind,id);assert.equal(after.lines[0].quantity,2);const audit=(await db.query("select user_id,old_values,new_values from audit_log where company_id=$1 and entity_type=$2 and entity_id=$3 and action='LINE_UPDATE' order by id desc limit 1",[c,kind,id])).rows[0];assert.equal(audit.old_values.line.quantity,1);assert.equal(audit.new_values.line.quantity,2);
 await assert.rejects(save(kind,id,after,after.header,after.lines.map(l=>({...l,quantity:6}))),/exceeds/);assert.deepEqual(await snapshot(kind,id),after);
 await assert.rejects(save(kind,id,after,after.header,after.lines.map(l=>({...l,unit_price:1}))),/Invalid/);
 const deletedId=(await db.query(`select ${sales?'create_sales_credit_note':'create_purchase_debit_note'}($1,'Deleted return',$2) id`,[source,JSON.stringify([{line_id:line,quantity:1}])])).rows[0].id;
 await db.query(`delete from ${kind} where id=$1`,[deletedId]);const deletedAudit=(await db.query("select old_values from audit_log where company_id=$1 and entity_type=$2 and entity_id=$3 and action='DOCUMENT_DELETE'",[c,kind,deletedId])).rows[0];assert.equal(deletedAudit.old_values._lines[0].quantity,1);
 await db.query(`select ${sales?'post_sales_credit_note':'post_purchase_debit_note'}($1)`,[id]);await assert.rejects(save(kind,id,after),/Only an accessible draft/);const [postedLines,postedParent]=childInfo[kind];await assert.rejects(db.query(`update ${postedLines} set quantity=quantity+1 where ${postedParent}=$1`,[id]),/immutable|original invoice line|original purchase-bill line/);await assert.rejects(db.query(`delete from ${postedLines} where ${postedParent}=$1`,[id]),/immutable/);assert.equal(Number((await db.query(`select quantity from ${postedLines} where ${postedParent}=$1`,[id])).rows[0].quantity),2);
 console.log(`${kind}: original source limits, fixed prices, rollback and posted lock passed.`);
}
// Master edits use the real RLS, server validation, audit triggers and optimistic snapshots.
const masterCols={employees:['full_name','designation','department','phone','email','address','base_salary','monthly_income_tax','monthly_eobi','monthly_sessi','tax_enabled','eobi_enabled','sessi_enabled','active'],attendance:['status','check_in','check_out','overtime_hours','notes'],leave_requests:['leave_type','start_date','end_date','paid','reason'],bank_accounts:['name','bank_name','account_number','iban','active'],branches:['name','city','active']};
const employee=(await db.query("insert into employees(company_id,branch_id,employee_code,full_name,join_date,base_salary) values($1,$2,'E-1','Test employee','2026-10-01',10000) returning id",[c,b])).rows[0].id;
const attendance=(await db.query("select record_employee_attendance($1,$2,'2026-10-16','present','09:00','17:00',0,'Original') id",[c,employee])).rows[0].id;
const leave=(await db.query("select submit_employee_leave($1,$2,'annual','2026-10-20','2026-10-21',true,'Original') id",[c,employee])).rows[0].id;
const bankLedger=(await db.query("select id from accounts where company_id=$1 and code='1010'",[c])).rows[0]?.id??(await db.query("select id from accounts where company_id=$1 and code='1000'",[c])).rows[0].id;
const bank=(await db.query("insert into bank_accounts(company_id,name,ledger_account_id) values($1,'Review bank',$2) returning id",[c,bankLedger])).rows[0].id;
for(const [kind,id,change] of [['employees',employee,{full_name:'Revised employee',base_salary:12000}],['attendance',attendance,{overtime_hours:2}],['leave_requests',leave,{reason:'Revised leave'}],['bank_accounts',bank,{name:'Revised bank'}],['branches',b,{city:'Karachi'}]]){
 const get=async()=>project((await db.query(`select to_jsonb(t) data from ${kind} t where id=$1`,[id])).rows[0].data,masterCols[kind]);
 const old=await get(),values={...old,...change};
 const update=(expected,next)=>db.query('select update_reviewed_master($1,$2,$3,$4,$5)',[c,kind,id,JSON.stringify(expected),JSON.stringify(next)]);
 await update(old,values);assert.deepEqual(await get(),values);await assert.rejects(update(old,values),/changed/);await assert.rejects(update(values,{...values,company_id:c}),/Invalid master fields/);
 assert.ok(Number((await db.query("select count(*) n from audit_log where company_id=$1 and entity_type=$2 and entity_id=$3 and action='UPDATE'",[c,kind,id])).rows[0].n)>0);
 if(kind==='attendance')await assert.rejects(update(values,{...values,check_out:'08:00:00'}),/Check-out/);
 if(kind==='employees')await assert.rejects(update(values,{...values,base_salary:-1}),/Invalid salary/);
 if(kind==='leave_requests'){await db.query("select review_employee_leave($1,'approved')",[id]);await assert.rejects(update(values,{...values,reason:'Should fail'}),/Reviewed leave/);}
 console.log(`${kind}: reviewed edit, concurrency, field whitelist and audit trail passed.`);
}
// Payroll period editing recalculates a draft atomically; posted payroll cannot be changed.
const run=(await db.query("insert into payroll_runs(company_id,branch_id,period_start,period_end,created_by) values($1,$2,'2026-10-01','2026-10-31',$3) returning id",[c,b,u])).rows[0].id;
await db.query('select prepare_payroll_run($1)',[run]);
await db.query("select update_reviewed_payroll_period($1,$2,'2026-10-01','2026-10-31','2026-11-01','2026-11-30')",[c,run]);
assert.equal((await db.query('select period_start::text start from payroll_runs where id=$1',[run])).rows[0].start,'2026-11-01');
assert.equal(Number((await db.query('select base_salary from payroll_items where payroll_run_id=$1',[run])).rows[0].base_salary),12000);
await assert.rejects(db.query("select update_reviewed_payroll_period($1,$2,'2026-10-01','2026-10-31','2026-12-01','2026-12-31')",[c,run]),/changed/);
await db.query('select post_payroll_run($1)',[run]);await assert.rejects(db.query("select update_reviewed_payroll_period($1,$2,'2026-11-01','2026-11-30','2026-12-01','2026-12-31')",[c,run]),/Only a payroll draft/);
console.log('Payroll period: atomic recalculation, current employee inputs, stale edits and posted lock passed.');
// Core draft replacement preserves complete old/new line evidence, not only a header log.
for(const sales of [true,false]){
 const kind=sales?'sales_invoices':'purchase_bills',fn=sales?'save_sales_invoice_draft':'save_purchase_bill_draft';
 const h={company_id:c,branch_id:b,[sales?'customer_id':'supplier_id']:contact,[sales?'invoice_date':'bill_date']:'2026-10-16',due_date:'2026-11-16'};
 const original={description:'Original core detail',quantity:2,unit_price:100,gst_rate:18,...(!sales?{expense_account_id:account}:{})};
 const id=(await db.query(`select ${fn}(null,$1,$2,false) id`,[JSON.stringify(h),JSON.stringify([original])])).rows[0].id;
 await db.query(`select ${fn}($1,$2,$3,false)`,[id,JSON.stringify(h),JSON.stringify([{...original,description:'Changed core detail',quantity:3,unit_price:120}])]);
 const events=(await db.query("select action,old_values,new_values from audit_log where company_id=$1 and entity_type=$2 and entity_id=$3 and action like 'LINE_%' order by id",[c,kind,id])).rows;
 assert.deepEqual(events.map(e=>e.action),['LINE_INSERT','LINE_DELETE','LINE_INSERT']);assert.equal(events[1].old_values.line.quantity,2);assert.equal(events[1].old_values.line.description,'Original core detail');assert.equal(events[2].new_values.line.quantity,3);assert.equal(events[2].new_values.line.unit_price,120);
 const count=events.length;await assert.rejects(db.query(`select ${fn}($1,$2,$3,false)`,[id,JSON.stringify(h),JSON.stringify([{...original,quantity:-1}])]));assert.equal((await db.query("select id from audit_log where company_id=$1 and entity_type=$2 and entity_id=$3 and action like 'LINE_%'",[c,kind,id])).rows.length,count);
}
// Reparented drafts log separate source/destination snapshots without cross-company before-value leakage.
const otherCompany=(await db.query("select create_company('Other audit company') id")).rows[0].id;
const otherBranch=(await db.query('select id from branches where company_id=$1 limit 1',[otherCompany])).rows[0].id;
const otherContact=(await db.query("insert into contacts(company_id,name,kind) values($1,'Other customer','customer') returning id",[otherCompany])).rows[0].id;
const quote=async(company,branch,customer)=>(await db.query("insert into quotations(company_id,branch_id,customer_id,quotation_date,created_by) values($1,$2,$3,'2026-10-16',$4) returning id",[company,branch,customer,u])).rows[0].id;
const qa=await quote(c,b,contact),qb=await quote(otherCompany,otherBranch,otherContact);
const moved=(await db.query("insert into quotation_lines(quotation_id,description,quantity,unit_price,gst_rate) values($1,'Source-only detail',1,100,0) returning id",[qa])).rows[0].id;
await db.query("update quotation_lines set quotation_id=$1,description='Destination detail',unit_price=200 where id=$2",[qb,moved]);
const sourceAudit=(await db.query("select old_values,new_values from audit_log where company_id=$1 and entity_type='quotations' and entity_id=$2 and action='LINE_DELETE'",[c,qa])).rows[0];const destinationAudit=(await db.query("select old_values,new_values from audit_log where company_id=$1 and entity_type='quotations' and entity_id=$2 and action='LINE_INSERT'",[otherCompany,qb])).rows[0];assert.equal(sourceAudit.new_values,null);assert.equal(sourceAudit.old_values.line.unit_price,100);assert.equal(destinationAudit.old_values,null);assert.equal(destinationAudit.new_values.line.unit_price,200);assert.ok(!JSON.stringify(destinationAudit).includes('Source-only detail'));
assert.equal((await db.query("select has_function_privilege('authenticated','public.audit_document_line_change()','EXECUTE') allowed")).rows[0].allowed,false);
console.log('All eight line sources: before/after evidence, no-op suppression, failed-transaction rollback, replacement history and company-safe moves passed.');
// Genuine RLS denies read-only and unrelated users, even with execute permission.
const viewer='00000000-0000-0000-0000-000000000099';await db.exec('reset role');await db.query('insert into auth.users(id,email) values($1,$2)',[viewer,'viewer@example.test']);await db.query("insert into company_members(company_id,user_id,role) values($1,$2,'viewer')",[c,viewer]);await db.exec(`set role authenticated;set test.uid='${viewer}'`);
await assert.rejects(save('quotations','00000000-0000-0000-0000-000000000001',{header:{},lines:[]}),/permission/);
await assert.rejects(save('quotations','00000000-0000-0000-0000-000000000001',{header:{},lines:[]},{},[],'00000000-0000-0000-0000-000000000098'),/permission/);
await assert.rejects(db.query('select update_reviewed_master($1,$2,$3,$4,$5)',[c,'employees',employee,'{}','{}']),/permission/);
assert.equal(Number((await db.query('select count(*) n from audit_log where company_id=$1',[otherCompany])).rows[0].n),0);
await db.exec(`set test.uid='${u}'`);
assert.equal((await db.query("select prosecdef from pg_proc where proname='update_reviewed_draft'")).rows[0].prosecdef,false);
assert.equal((await db.query("select prosecdef from pg_proc where proname='update_reviewed_master'")).rows[0].prosecdef,false);
await db.close();console.log('Reviewed draft edits preserve RLS and accounting boundaries.');
