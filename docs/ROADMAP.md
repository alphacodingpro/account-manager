# Product roadmap

## Milestone 1 — Foundation

- [x] Authentication and profile
- [x] Company onboarding and multi-company switcher
- [x] Branch creation and live branch list
- [x] Chart of Accounts and balanced journal engine foundation
- [x] Custom accounts, journal posting and transaction history
- [x] Responsive white/blue application shell
- [x] Owner-controlled company invitations and company-level permission editor
- [x] Least-privilege Sales Staff role with backend enforcement and restricted navigation
- [x] Least-privilege Purchase Staff role with supplier, bill posting and reversal controls
- [x] Least-privilege Inventory Staff role with append-only adjustments and warehouse transfers

## Milestone 2 — Sales and purchases

- [x] Customers and GST sales invoices
- [x] Automatic receivable, sales and output-GST journal posting
- [x] Sales quotation drafts, approval and controlled invoice conversion
- [x] Purchase order approval and controlled partial receiving into bill drafts
- [x] Sales orders with controlled partial delivery into invoice drafts
- [x] Bills, customer receipts and supplier payments with safe reversal
- [x] Sales returns and credit notes with stock, GST and receivable reversal
- [x] Purchase returns and supplier debit notes with stock, GST and payable reversal
- [x] Historical receivable/payable aging by document and allocated-payment date
- PDF sales and purchase documents

## Milestone 3 — Inventory

- [x] Products, services, prices, units and reorder levels
- [x] Warehouses, branch stock, transfers, adjustments and reorder alerts
- [x] Weighted-average valuation with warehouse-wise stock ledger

## Milestone 4 — Reporting

- [x] Live dashboard balances, monthly trend and recent transactions
- [x] General Ledger, Trial Balance, Profit & Loss, Balance Sheet and direct-method Cash Flow
- [x] Excel-compatible CSV export and print/PDF-ready financial reports
- Branch comparison and dashboard drill-down

## Milestone 4.5 — Banking

- [x] Bank account setup and cash/bank receipt/payment entry
- [x] Draft posting, document allocation and audit-safe payment reversal
- [x] Bank statement CSV import, duplicate detection and payment matching
- [x] Controlled reconcile/unreconcile workflow with audit history

## Milestone 5 — Payroll

- Attendance, leave, salary, allowances, deductions and loans
- Configurable EOBI, SESSI and income-tax rules with effective dates
- Payslips and automatic accounting entries

### Manager-style sales entry parity (retain current design)
- [x] Invoice date, customer, reference, quantity, unit price and add line
- [x] Specific due date or Net days (0–3650)
- [x] Save draft / Post and add another (reset lines/reference only after success)
- [ ] Invoice billing-address snapshot and header description
- [ ] Per-line income account and discount with GST/accounting validation
- [ ] Line number / description / discount column controls
- [ ] Rounding with explicit ledger adjustment
- [ ] Early-payment discounts and late-payment fees with auditable posting
- [ ] Print: words/base-currency totals, custom title, hide due date/balance
- [ ] Item images, delivery-note mode, footers and attachment upload

### Planned sidebar module implementation queue
- [x] Customers and Suppliers: company-scoped paginated directory, search, create/edit, NTN/STRN and safe deactivation/reactivation
- [x] Dedicated Receipts and Payments pages with direction-specific entry and complete searchable lists
- [x] Inter Account Transfers: atomic cash/bank journal posting with company/account validation; existing Accounting reversal path
- [x] Expense Claims core: journal-backed capture, atomic draft edits/posting, full view, search, deletion and reversal
- [x] Expense Claims: full cash/bank reimbursement, duplicate prevention and reversal/reimbursement guard
- [x] Expense Claims: partial reimbursements, paid/remaining balance, per-payment reversal and retry idempotency
- [ ] Expense Claims: receipt attachments and dedicated approval workflow
- [ ] Billable Time
- [x] Invoice/bill-backed Delivery Notes and Goods Receipts: goods-only searchable directory, full quantity view and print/PDF without duplicate stock posting
- [x] Independent uninvoiced delivery/receipt draft capture, atomic JSON line edits, review/delete, search and company/role validation
- [ ] Independent goods posting, physical handover confirmation, invoice/bill linking and returns-aware quantities
- [x] Stock-product Purchase Quotes: company-scoped searchable drafts, edit/delete, approval lock and atomic purchase-order conversion
- [x] Purchase Quotes: service/expense-only lines, validated expense-account conversion and dedicated print/view
- [x] Inventory Write-offs: atomic stock-loss/expense posting, source reversal, journal-only reversal guard (requires inventory + accounting permission)
- [ ] Production Orders
- [x] Payslips directory: posted payroll only, employee/period search, full earnings/deductions and print/PDF
- [ ] Projects
- [ ] Fixed Assets and Depreciation Entries
- [ ] Intangible Assets and Amortization Entries
- [ ] Investments, Capital Accounts and Special Accounts
- [x] Late Payment Fees: overdue balance validation, atomic separate fee invoice, explicit GST, duplicate-date protection; normal sales posting/voiding and receipt allocation
- [ ] Withholding Tax Receipts
- [ ] Folders and Customize
Every transactional module requires company/role enforcement, draft review, balanced posting, audit-safe cancellation and relevant validation before its Planned badge is removed.
