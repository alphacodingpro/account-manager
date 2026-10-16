# List search and record review

The existing navigation and accounting workflows are retained. Shared controls provide compact list search, complete record dialogs and reviewed editing.

| Screen | Search | Full view | Editing |
| --- | --- | --- | --- |
| Sales invoices / purchase bills | Yes | Existing complete views | Existing draft editor and controlled source correction |
| Sales quotations / sales orders / purchase orders | Yes, including older pages | Header and every line | Draft details and existing line description, quantity, price and GST |
| Sales credit notes / purchase debit notes | Yes, notes and source documents | Header and every return line | Draft date, reason and return quantities; source prices and identities retained |
| Accounts / products / contacts | Yes | Complete record dialog | Existing editors; system account and stock value restrictions retained |
| Warehouse stock / stock movements / write-offs | Yes | Product / immutable movement / journal details | Source workflows only |
| Payroll employees / attendance / leave | Yes, including older pages | Full details and employee salary components | Reviewed master edits; reviewed leave is locked |
| Payroll runs | Yes, including older pages | Header and all payroll items | Draft period edit atomically recalculates payroll; posted runs remain locked |
| Bank accounts / payments / reconciliation | Yes | Bank details and existing payment review | Bank metadata and existing payment draft editor; ledger identity retained |
| Branches / team | Yes | Branch details / existing member details | Reviewed branch metadata / existing role controls |
| Reports | Yes | Existing reports | Read-only financial results; search does not change full-report CSV or print |

## Safety contract

- Migration `0053_reviewed_document_edits.sql` is append-only. It does not change RLS policies or mutate existing business data.
- Edit RPCs run as security invoker, enforce module access, company ownership and current draft status, lock records, and compare the user's review snapshot before saving.
- Draft line IDs and product/account/source links are retained. These dialogs edit existing lines; creation and source replacement continue through the existing document workflows.
- Every header and line change in a draft edit is one database transaction. Any validation failure leaves the original draft intact.
- Return quantities remain subject to original-source limits and existing posting/stock/GST guards. Return editors cannot override original prices.
- Payroll master changes affect future preparation. Posted payroll items and ledger entries are not edited.
- Master edits preserve identity, validate attendance/leave rules and record old/new values in the company audit log.
- Lists read pages of 500 records instead of silently searching only the first 12–50 records. A failed page is reported instead of displaying a misleading partial result.
- Modal dialogs support Escape, close, cancellation without saving, responsive scrolling and stale-request protection.

## Verification

`npm run typecheck`, `npm test`, `npm run build`, `npm run test:db`.

The reviewed-edit database test applies all migrations to an isolated PostgreSQL instance, then exercises the actual RLS, document guards, audit triggers and posting functions. It covers all six document edit types, five master types, payroll recalculation, stale snapshots, immutable posted/approved records, return limits and rollback after a later line fails.

Browser checks at 390px and 1280px exercise search, complete line review, cancel without writes, Escape, edit payloads, bank editing and posted edit-button suppression using test fixtures. No production financial data is used in browser tests.

## Line-level history evidence

Migration `0054_document_line_audit.sql` records prospective line insert/update/delete evidence for invoices, bills, quotations, sales/purchase orders, credit/debit notes and journals. Before/after snapshots include descriptions, quantities, prices, GST and generated amounts. Actual no-op updates do not create line events. Audit events participate in the same transaction as the business change and disappear if that transaction fails.

Deleting a draft retains its complete line snapshot before the foreign-key cascade. Existing invoice/bill restoration remains unchanged; deletion snapshots for other document families provide review evidence and do not add unsupported Undo actions. A narrowly scoped cascade guard correction permits deleting draft quotations/orders/returns while retaining ordinary draft-parent checks, RLS and posted/approved record immutability.

History details flatten nested line values into a readable Before/After table, default to changed fields, and permit reviewing all fields. Search includes both old and new values, so deleted descriptions are searchable. Historical gaps are not backfilled or reconstructed. For a line moved between accessible company drafts, source and destination events contain only their own side of the change.
