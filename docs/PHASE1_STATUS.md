# Phase 1 readiness checklist

Code inspection: 16 October 2026. This records implementation and acceptance gaps; it is not a declaration that Phase 1 is complete. The working scope is the core accounting, sales/purchases, stock, payroll, invoice GST and multi-company workflows requested in this project. Advanced sidebar modules remain separately tracked in ROADMAP.md.

| Area | Current code evidence | Remaining acceptance work |
| --- | --- | --- |
| Sales/purchase draft safety | Atomic create/edit/post RPCs in migration 0045; both entry screens use them; failed insert/post rollback tests | Verify draft edits and posting failure in a signed-in browser, including imported bills and order-linked documents |
| Physical goods | Draft capture, bill/invoice conversion, selected warehouse, posted-document full/partial confirmation, cancellation and returns-aware remaining quantities (0036, 0040–0043, 0046–0049) | Known-cost independent receipts now post Inventory/GRNI and match a full bill with explicit expense price variance without duplicate stock; unused receipt reversal is supported. Independent dispatch posts a clearing asset and invoices transfer its original cost to COGS without repeating stock. Receipt billing supports reserved partial quantities with exact cumulative cost clearing. Partial delivery invoicing and reversal after later stock activity remain |
| Sales entry and documents | Customer, branch, dates, terms, reference, line description, quantity, price, GST, draft/post/correction | Billing-address snapshot/header description; per-line income account/discount; controlled rounding; consistent dedicated full view/print; print options |
| Purchases | Stock/service/expense bills, input GST, drafts, payments, returns and order receiving | End-to-end imported bill review, duplicate supplier-reference behavior under concurrent saves, and consistent full view/print acceptance |
| Payroll | Employee, attendance/leave capture, fixed allowances/deductions, payroll preparation/posting and payslip directory; loan schema/basic recovery calculation exists | Loan management UI and multiple-loan recovery review; attendance/leave-driven calculation; period/proration/duplicate-payroll protection; effective-dated EOBI/SESSI/income-tax configuration and tests |
| Documents/OCR | PDF text/table parsing, line review, document tests and local OCR service code exist | Representative real scanned bills/images must pass extraction, line reconciliation and account mapping review; arbitrary-format accuracy is not established |
| Permissions | Company permission checks, company-scoped data, restricted sales/purchase/inventory roles; isolated negative tests | Signed-in role switching/direct-route checks and branch-specific authorization acceptance across all mutation paths |
| Reports/GST | GL, trial balance, P&L, balance sheet, cash flow, aging, GST posting, CSV/print | Full-chain sale/purchase/payment/return/reversal reconciliation against stock and all reports, with date-boundary checks |
| Audit and recovery | Global history, source reversals, draft restoration subset, immutable confirmation evidence, source-journal reversal guards | Consistent source navigation and documented undo/restore coverage; browser verification for each supported transaction type |
| UX and reliability | Grouped sidebar, shared visual classes, responsive tables; CI type checks, API/document tests, isolated DB tests and builds gate migrations | Cross-module form/view consistency, mobile keyboard/table checks, full clean-database migration integration test and final production smoke pass |

## Completion rule

Phase 1 closes only when its remaining functional rows above have a working path and the end-to-end acceptance cases pass. Isolated tests sometimes mock posting or stock; they do not replace a complete Supabase integration run or user testing. No completion date is asserted from a count of committed features.

## Execution order

1. Preserve draft edits atomically in both core sales and purchase flows (implemented in this increment).
2. Extend the implemented dispatch flow to partial invoicing with controlled valuation reversals.
3. Finish sales entry/document gaps and payroll calculation/loan/rule gaps.
4. Complete real-document OCR verification and cross-module UX consistency.
5. Run company/role/branch, stock-to-ledger, reporting and mobile acceptance; resolve failures before closing the phase.
