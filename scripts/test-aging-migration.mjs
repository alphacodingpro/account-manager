import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(new URL("../supabase/migrations/0018_historical_aging_accuracy.sql", import.meta.url), "utf8");
for (const functionName of ["get_receivable_aging", "get_payable_aging"]) {
  assert.match(sql, new RegExp(`create or replace function public\\.${functionName}`));
}
assert.match(sql, /invoice_date<=as_of/);
assert.match(sql, /bill_date<=as_of/);
assert.match(sql, /payment_date<=as_of/g);
assert.match(sql, /p\.status='posted'/g);
assert.match(sql, /p\.company_id=i\.company_id/);
assert.match(sql, /p\.company_id=b\.company_id/);
assert.match(sql, /not public\.is_company_member\(target_company\)/g);
assert.match(sql, /revoke all on function public\.get_receivable_aging\(uuid,date\) from public,anon/);
assert.match(sql, /revoke all on function public\.get_payable_aging\(uuid,date\) from public,anon/);
console.log("Historical aging migration safety checks passed.");
