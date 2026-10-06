import assert from "node:assert/strict"; import { readFileSync } from "node:fs";
const sql=readFileSync(new URL("../supabase/migrations/0020_purchase_order_receiving.sql",import.meta.url),"utf8");
for(const text of ["has_company_permission(o.company_id,'purchases')","Approved purchase order is immutable","Use the controlled purchase order workflow","Purchase order has already been received to a bill","purchase_order_audit","converted_bill_id=new_bill"])assert.ok(sql.includes(text),`Missing: ${text}`);
assert.match(sql,/insert into public\.purchase_bills/);assert.match(sql,/insert into public\.purchase_bill_lines/);assert.doesNotMatch(sql,/post_purchase_bill\s*\(/);assert.doesNotMatch(sql,/stock_movements|journal_entries/);
console.log("Purchase order workflow migration safety checks passed.");
