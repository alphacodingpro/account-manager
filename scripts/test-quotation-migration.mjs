import assert from "node:assert/strict"; import { readFileSync } from "node:fs";
const sql=readFileSync(new URL("../supabase/migrations/0019_sales_quotation_workflow.sql",import.meta.url),"utf8");
for(const text of ["has_company_permission(q.company_id,'sales')","Approved quotation is immutable","Use the controlled quotation workflow","New quotation must start as an empty draft","Quotation has already been converted","Invoice due date cannot be in the past","quotation_audit","converted_invoice_id=new_invoice"])assert.ok(sql.includes(text),`Missing: ${text}`);
assert.match(sql,/insert into public\.sales_invoices/);assert.match(sql,/insert into public\.sales_invoice_lines/);assert.doesNotMatch(sql,/post_sales_invoice\s*\(/);assert.doesNotMatch(sql,/stock_movements|journal_entries/);
console.log("Quotation workflow migration safety checks passed.");
