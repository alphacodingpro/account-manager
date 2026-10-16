import {build} from 'esbuild';import {mkdtempSync,rmSync} from 'node:fs';import {tmpdir} from 'node:os';import {join} from 'node:path';import {createRequire} from 'node:module';import assert from 'node:assert/strict';
const dir=mkdtempSync(join(tmpdir(),'record-tools-'));
try{
 await build({entryPoints:['apps/web/src/lib/searchRecords.ts','apps/web/src/lib/listRecords.ts'],bundle:true,outdir:dir,platform:'node',format:'cjs',outExtension:{'.js':'.cjs'}});
 const require=createRequire(import.meta.url),{matchesRecord}=require(join(dir,'searchRecords.cjs')),{listRecords}=require(join(dir,'listRecords.cjs'));
 const row={invoice_number:123,contacts:{name:'Ubaid Traders'},total:1234.5,status:'draft',notes:null};
 assert.ok(matchesRecord(row,'INV-000123 traders 1,234.50'));assert.ok(matchesRecord(row,'  UBAID   draft '));assert.ok(matchesRecord(row,''));assert.equal(matchesRecord(row,'traders paid'),false);assert.ok(matchesRecord({entry_number:8},'JV-00008'));
 const records=Array.from({length:1251},(_,id)=>({id,name:`Record ${id}`})),calls=[];
 const result=await listRecords({range:async(from,to)=>{calls.push([from,to]);return {data:records.slice(from,to+1),error:null}}});assert.equal(result.data.length,1251);assert.deepEqual(calls,[[0,499],[500,999],[1000,1499]]);assert.ok(result.data.filter(r=>matchesRecord(r,'1250')).some(r=>r.id===1250));
 const failed=await listRecords({range:async(from)=>from===0?{data:records.slice(0,500),error:null}:{data:null,error:{message:'Read denied'}}});assert.equal(failed.data,null);assert.equal(failed.error.message,'Read denied');
 console.log('Record search: document numbers, nested contacts, amounts, AND terms, full pagination and failed-page handling passed.');
}finally{rmSync(dir,{recursive:true,force:true});}
