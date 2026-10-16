import {build} from 'esbuild';import {mkdtempSync,rmSync} from 'node:fs';import {tmpdir} from 'node:os';import {join} from 'node:path';import {createRequire} from 'node:module';import assert from 'node:assert/strict';
const dir=mkdtempSync(join(tmpdir(),'sidebar-test-'));const storage=new Map();globalThis.localStorage={getItem:key=>storage.get(key)??null,setItem:(key,value)=>storage.set(key,value)};
try{
 await build({entryPoints:['apps/web/src/lib/sidebarPreferences.ts'],bundle:true,outfile:join(dir,'prefs.cjs'),platform:'node',format:'cjs'});
 const {sidebarPreferenceKey,readSidebarPreferences,saveSidebarPreferences,sidebarGroupVisible}=createRequire(import.meta.url)(join(dir,'prefs.cjs'));
 const a=sidebarPreferenceKey('user1','company1'),b=sidebarPreferenceKey('user1','company2'),other=sidebarPreferenceKey('user2','company1');
 assert.deepEqual(readSidebarPreferences(a),[]);assert.equal(saveSidebarPreferences(a,['Sales:orders','Sales:orders']),true);assert.deepEqual(readSidebarPreferences(a),['Sales:orders']);assert.deepEqual(readSidebarPreferences(b),[]);assert.deepEqual(readSidebarPreferences(other),[]);
 const group={id:'Sales',label:'Sales',items:[{id:'Sales:orders'},{id:'Sales:invoices'}]};assert.equal(sidebarGroupVisible(['Sales:orders'],group),true);assert.equal(sidebarGroupVisible(['Sales:orders','Sales:invoices'],group),false);assert.equal(sidebarGroupVisible(['Sales'],group),false);
 storage.set(a,'bad JSON');assert.deepEqual(readSidebarPreferences(a),[]);storage.set(a,JSON.stringify({version:999,hidden:['Sales']}));assert.deepEqual(readSidebarPreferences(a),[]);storage.set(a,JSON.stringify({version:1,hidden:[null,123,'Sales']}));assert.deepEqual(readSidebarPreferences(a),['Sales']);
 globalThis.localStorage={getItem(){throw Error('blocked')},setItem(){throw Error('blocked')}};assert.deepEqual(readSidebarPreferences(a),[]);assert.equal(saveSidebarPreferences(a,['Sales']),false);
 console.log('Sidebar preferences: user/company isolation, persistence, defaults, empty groups, corrupt/blocked storage passed.');
}finally{delete globalThis.localStorage;rmSync(dir,{recursive:true,force:true});}
