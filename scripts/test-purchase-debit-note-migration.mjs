import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const sql=await readFile(new URL("../supabase/migrations/0024_purchase_debit_notes.sql",import.meta.url),"utf8");
const required=[
 /create table public\.purchase_debit_notes/,
 /create table public\.purchase_debit_note_lines/,
 /references public\.purchase_bill_lines/,
 /has_company_permission\([^\n]+,'purchases'\)/,
 /Returned quantity exceeds the original purchase bill/,
 /'return_out'/,
 /'return_in'/,
 /ap,'Supplier debit',grand,0/,
 /input_gst,'Input GST reversal',0,tax/,
 /inventory,'Inventory returned',0,stock_cost/,
 /Purchase return variance/,
 /select sum\(n\.total\) from public\.purchase_debit_notes n/,
 /security_invoker=true/,
 /Payment exceeds bill balance after debit notes/,
 /linked debit notes before voiding this bill/,
];
for(const pattern of required)assert.match(sql,pattern,`Missing purchase debit-note protection: ${pattern}`);
assert.doesNotMatch(sql,/update public\.purchase_bills set total=/i,"Posted purchase bill totals must not be rewritten");
console.log("Purchase debit-note migration checks passed.");
