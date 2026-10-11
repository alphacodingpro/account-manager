begin;
create trigger sales_invoice_audit after insert or update or delete on public.sales_invoices
for each row execute function public.write_audit_log();
commit;
