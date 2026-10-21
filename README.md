# CloudLedger PK

Cloud accounting for Pakistani businesses: double-entry books, sales and purchases with GST, inventory,
banking, payroll, branches, team roles, audit history and professional PDF documents.

- **Web app:** React + TypeScript (`apps/web`)
- **Database and rules:** Supabase / PostgreSQL migrations (`supabase/migrations`). Every accounting rule
  (posting, reversals, immutability, GST, stock valuation, books lock) lives here and is covered by tests.
- **Optional services:** `services/document-ocr` (scan supplier bills), `apps/api` (health check only)

## What it does
Sales quotations, orders, delivery notes, invoices, credit notes, late fees; purchase quotes, orders, goods receipts,
bills, debit notes, expense claims; bank and cash accounts, receipts, payments, transfers, reconciliation;
inventory with weighted-average valuation, warehouses, adjustments, write-offs; payroll with attendance and leave;
chart of accounts and journals; Trial Balance, Profit & Loss, Balance Sheet, Cash Flow, aging and GST summary;
books lock date; full data backup; PDF export of every document and report with your company letterhead.

## Run it locally
    npm install
    cp apps/web/.env.example apps/web/.env       # add your Supabase URL and anon key
    npm run dev -w @cloudledger/web

You need a Supabase project with **all** migrations applied (`supabase db push`). See `docs/DEPLOYMENT.md`.

## Quality checks
    npm test            # database rules (full migration chain on PostgreSQL), PDF, reports, UI helpers
    npm run build -w @cloudledger/web

## Documents
- `docs/DEPLOYMENT.md` - production setup, backups, upgrades
- `docs/COMMERCIAL_READINESS.md` - what to decide and finish before selling to customers
- `docs/MANAGER_PARITY.md` - feature comparison with Manager.io and the roadmap
- `docs/ROADMAP.md` - phase plan
