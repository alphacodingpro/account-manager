import {build} from 'esbuild';import {mkdtempSync,rmSync} from 'node:fs';import {tmpdir} from 'node:os';import {join} from 'node:path';import {createRequire} from 'node:module';import assert from 'node:assert/strict';
const dir=mkdtempSync(join(tmpdir(),'activity-test-'));
try{
 await build({entryPoints:['apps/web/src/lib/activityChanges.ts'],bundle:true,outfile:join(dir,'activity.cjs'),platform:'node',format:'cjs'});const {activityChanges}=createRequire(import.meta.url)(join(dir,'activity.cjs'));
 const before={status:'draft',line:{description:'Original cable',quantity:2,unit_price:100,total:200}},after={status:'draft',line:{description:'Revised cable',quantity:4,unit_price:125,total:500}};
 const rows=activityChanges(before,after);assert.deepEqual(rows.find(r=>r.field==='line.quantity'),{field:'line.quantity',before:'2',after:'4',changed:true});assert.equal(rows.find(r=>r.field==='status').changed,false);assert.ok(rows.filter(r=>r.changed).every(r=>r.field.startsWith('line.')));
 const deletion=activityChanges({line:{description:'Deleted detail',quantity:0},active:false},null);assert.equal(deletion.find(r=>r.field==='line.quantity').before,'0');assert.equal(deletion.find(r=>r.field==='active').before,'No');assert.equal(deletion.find(r=>r.field==='line.description').after,'—');
 const arrays=activityChanges({lines:[{description:'Item'}]}, {lines:[{description:'New item'}]});assert.ok(arrays[0].after.includes('New item'));assert.ok(!arrays[0].after.includes('[object Object]'));assert.deepEqual(activityChanges(null,null),[]);
 console.log('Activity details: nested line differences, unchanged fields, deletion evidence, zero/false values and arrays passed.');
}finally{rmSync(dir,{recursive:true,force:true});}
