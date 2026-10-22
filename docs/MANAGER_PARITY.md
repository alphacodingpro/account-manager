# Feature comparison with Manager.io (status after the October 2026 audit)

Legend: **Yes** works end to end. **Partial** works with limits. **No** not built.

## Banking
| Feature | Status |
|---|---|
| Bank and cash accounts, receipts, payments, inter-account transfers | Yes |
| Bank reconciliation with statement import | Yes |
| Bank rules, bank feeds | No |

## Sales
| Feature | Status |
|---|---|
| Quotations, orders (partial delivery), delivery notes, invoices, credit notes | Yes |
| Customers with NTN/STRN, late payment fees, correction of posted invoices | Yes |
| Invoice notes / terms, per-line discounts, rounding | No |
| Recurring invoices | No |
| Customer statements of account (screen and PDF) | Yes |
| Named tax codes, withholding tax | No (GST % per line only) |
| Multi-currency | No (PKR only) |
| Email an invoice to the customer | No |

## Purchases
| Feature | Status |
|---|---|
| Quotes, orders, goods receipts, bills, debit notes, suppliers with payable balance, expense claims | Yes |
| Supplier statements of account (screen and PDF) | Yes |
| Recurring bills, discounts | No |
| Scan a supplier bill (OCR) | Yes (optional service) |

## Inventory
| Feature | Status |
|---|---|
| Items and services, warehouses, transfers, adjustments, write-offs, weighted-average valuation | Yes |
| FIFO, item groups, kits, serial/batch numbers, units of measure, barcodes | No |
| Production orders, projects, billable time | No |

## Payroll
| Feature | Status |
|---|---|
| Employees, attendance, leave, payroll runs, payslips (PDF), EOBI / SESSI / income tax fields | Yes |

## Accounting and reports
| Feature | Status |
|---|---|
| Chart of accounts (standard Pakistan set), manual journals, per-account history | Yes |
| Trial Balance, Profit & Loss, Balance Sheet (with earnings), Cash Flow, Receivable and Payable aging, **GST Summary** | Yes |
| Books lock date | Yes |
| General Ledger with opening and running balance (all accounts or one) | Yes |
| Sales and purchases by item or customer | No |
| Fixed assets and depreciation, intangibles and amortization, investments, capital and special accounts | No |
| Budgets, multi-period comparison, closing entries | No (earnings roll forward automatically) |
| Custom fields, folders, document templates | No |

## Platform
| Feature | Status |
|---|---|
| Multiple companies, branches, team roles and permissions, audit history | Yes |
| Full data backup (JSON), PDF export of documents and lists, CSV export of reports | Yes |
| Attachments on invoices and bills | Partial (expense claims only) |
| Import customers, suppliers and items from a file | No |
| FBR / e-invoicing integration | No |
| Urdu text in PDFs and the interface | No |
| Public API | No |

## Suggested order of work
1. Invoice notes and terms, per-line discounts, sales and purchases by item or customer.
2. Opening-balance wizard and CSV import of contacts and items.
3. Fixed assets with depreciation.
4. Recurring invoices and bills, email sending.
5. Withholding tax, multi-currency, budgets.
6. FBR integration and Urdu.
