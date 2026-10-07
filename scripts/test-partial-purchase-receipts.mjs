import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql=readFileSync(new URL("../supabase/migrations/0021_partial_purchase_receipts.sql",import.meta.url),"utf8");
assert.match(sql,/create_partial_purchase_bill/);
assert.match(sql,/received quantity exceeds the purchase-order balance/i);
assert.match(sql,/valid_count<>requested_count/);
assert.match(sql,/status<>'void'/);
assert.match(sql,/has_company_permission\(o\.company_id,'purchases'\)/);
assert.match(sql,/security_invoker=true/);
assert.match(sql,/purchase_order_line_id/);
assert.match(sql,/every purchase-order bill line must reference/i);
assert.match(sql,/company, branch, warehouse and supplier must match/i);
assert.match(sql,/purchase order has no remaining quantity/i);
assert.doesNotMatch(sql,/insert into public\.stock_movements/i);
assert.doesNotMatch(sql,/insert into public\.journal_entries/i);
console.log("Partial purchase receipt migration safety checks passed.");
