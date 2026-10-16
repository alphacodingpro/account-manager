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
const c=(await db.query("select create_company('Payroll integrity test') id")).rows[0].id;
const b=(await db.query('select id from branches where company_id=$1 limit 1',[c])).rows[0].id;

const employee=(await db.query("insert into employees(company_id,branch_id,employee_code,full_name,join_date,base_salary) values($1,$2,'P1','Payroll employee','2026-01-01',10000) returning id",[c,b])).rows[0].id;
const run=async(start,end,branch=b,company=c)=>(await db.query('insert into payroll_runs(company_id,branch_id,period_start,period_end,created_by) values($1,$2,$3,$4,$5) returning id',[company,branch,start,end,u])).rows[0].id;
const post=id=>db.query('select post_payroll_run($1)',[id]);
const original=await run('2026-01-01','2026-01-31');await post(original);
for(const dates of [['2026-01-01','2026-01-31'],['2026-01-31','2026-02-28'],['2025-12-15','2026-01-01'],['2026-01-10','2026-01-20']]){
 const id=await run(...dates,null);
 const before=(await db.query('select count(*) n from journal_entries where company_id=$1',[c])).rows[0].n;
 await assert.rejects(post(id),/overlaps an active posted payroll/);
 assert.equal((await db.query('select status from payroll_runs where id=$1',[id])).rows[0].status,'draft');
 assert.equal((await db.query('select count(*) n from journal_entries where company_id=$1',[c])).rows[0].n,before);
 assert.equal(Number((await db.query('select count(*) n from payroll_items where payroll_run_id=$1',[id])).rows[0].n),0);
}
const next=await run('2026-02-01','2026-02-28');await post(next);
// The check uses employee snapshots, even after the employee moves branch.
const secondBranch=(await db.query("insert into branches(company_id,name,code) values($1,'Second branch','B2') returning id",[c])).rows[0].id;
await db.query('update employees set branch_id=$1 where id=$2',[secondBranch,employee]);
const moved=await run('2026-01-01','2026-01-31',secondBranch);await assert.rejects(post(moved),/overlaps/);
await db.query("select void_payroll_run($1,'Replace reviewed payroll')",[original]);await post(moved);
// Different employees in a different branch can share the dates.
await db.query("insert into employees(company_id,branch_id,employee_code,full_name,join_date,base_salary) values($1,$2,'P2','Different employee','2026-01-01',9000)",[c,b]);
const separate=await run('2026-01-01','2026-01-30');await post(separate);
const otherCompany=(await db.query("select create_company('Other payroll company') id")).rows[0].id;
await db.query("insert into employees(company_id,employee_code,full_name,join_date,base_salary) values($1,'P1','Other company employee','2026-01-01',10000)",[otherCompany]);
await post(await run('2026-01-01','2026-01-31',null,otherCompany));
const isolationRun=await run('2026-03-01','2026-03-31',secondBranch);
await db.exec('begin isolation level repeatable read');
await assert.rejects(post(isolationRun),/READ COMMITTED/);await db.exec('rollback');
assert.equal((await db.query('select status from payroll_runs where id=$1',[isolationRun])).rows[0].status,'draft');
console.log('Payroll overlap, inclusive boundaries, company/branch snapshots, adjacent periods, reversal replacement and atomic journal rollback passed.');
console.log('Higher-isolation posting fails closed. True multi-connection concurrency is not simulated by PGlite.');
await db.close();
