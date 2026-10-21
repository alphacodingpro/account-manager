# Commercial readiness (October 2026 audit)

## Verified safe
- **Books balance.** An end-to-end test posts purchases, sales, receipts, payments, voids and journals on the full migration chain.
  Trial Balance debits equal credits, the Receivable ledger equals receivable aging, the Inventory ledger equals stock valuation,
  and the Balance Sheet balances including current-year and prior-year earnings.
- **Customer isolation.** Every one of the 61 tables has row-level security (the internal numbering table is deny-all on purpose). Every database function has a fixed search path.
  Signed-out visitors can no longer execute any function. Backup export never includes another company.
- **Posted records are immutable.** They can only be reversed. A books lock date blocks any change on or before a closed day.
- **Document numbers are per company** (INV-000001 for each company, not one shared counter).
- **No secrets are stored in the repository.**
- **Dependency licences are all permissive** (MIT, ISC, BSD, Apache-2.0), so commercial use is allowed.
  `npm audit` reports 3 moderate issues in `sprintf-js` (a parser used by the DOCX importer). It only handles files the user
  uploads themselves and has no fix available; accepted as low risk.

## Fixed during the audit
1. Voiding a posted receipt or payment failed with a database error. Fixed (migration 0058) with a regression test.
2. The Balance Sheet did not balance (no earnings in equity). Fixed (0059).
3. Documents numbers were shared by all companies. Fixed (0059).
4. No way to lock a closed period. Added (0059).
5. The default chart of accounts had 16 accounts. Now about 50 (0059).
6. Signed-out visitors could execute database functions. Closed (0060).
7. There was no data export. Added (0060).
8. Pakistan GST summary report added (0061).
9. Reports now align text left and numbers right, show totals, and zero as a dash.
10. Many UI issues (see docs below), including missing PDF buttons on invoice rows.

## You must decide or finish before selling
1. **Licence and terms.** `LICENSE` is a placeholder. Choose who owns the software, write the end-user agreement,
   Terms of Service and Privacy Policy with a lawyer.
2. **Hosting model.** Either you host one multi-company system (needs support, uptime, backups, a data-protection policy)
   or you set up one Supabase project per customer (simpler isolation, more operational work).
3. **Backups and restore.** Turn on Supabase backups, practise a restore. A restore tool for the JSON export does not exist yet.
4. **Email.** Configure your own SMTP in Supabase before inviting customers (sign-up and password-reset mails).
5. **Branding.** Do not use the Manager.io name, logo or text in the product or marketing. Copying features is fine; copying their
   code, screens or wording is not. The product currently contains no Manager.io branding.
6. **Tax rules.** GST is a rate per line. Withholding tax, further tax and FBR invoice integration are not built.
   Say so clearly to customers and get a Pakistani tax adviser to review the invoice and GST report layouts.
7. **Support process.** Error monitoring is not set up (for example Sentry) and there is no in-app help yet.

## Known limits
- Urdu or other non-Latin text appears as `?` in PDFs.
- Draft documents are numbered when created, so deleting a draft leaves a gap in the sequence.
- Large companies: lists are paged, but the full JSON backup runs in one request.
