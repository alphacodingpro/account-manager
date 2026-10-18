import { supabase } from "./supabase";
import { getPdfCompany, pdfDate, pdfMoney, pdfNumber, type PdfSpec } from "./pdfExport";

type ContactInfo = { name: string; email?: string | null; phone?: string | null; address?: string | null; ntn?: string | null; strn?: string | null } | null;
type DocLine = { description: string; quantity: number | string; unit_price: number | string; gst_rate: number | string; gst_amount?: number | string; total: number | string };

const pad = (n: number | string | null | undefined, width = 6) => String(n ?? "").padStart(width, "0");
const CONTACT = "name,email,phone,address,ntn,strn";

function partyLines(contact: ContactInfo): string[] {
  if (!contact) return [];
  return [contact.name, contact.address, [contact.phone && `Tel: ${contact.phone}`, contact.email].filter(Boolean).join("   "), [contact.ntn && `NTN: ${contact.ntn}`, contact.strn && `STRN: ${contact.strn}`].filter(Boolean).join("   ")].filter((x): x is string => !!x);
}

const lineColumns = [
  { header: "#", width: 9 },
  { header: "Description" },
  { header: "Qty", align: "right" as const, width: 17 },
  { header: "Unit price", align: "right" as const, width: 27 },
  { header: "GST %", align: "right" as const, width: 15 },
  { header: "GST amount", align: "right" as const, width: 25 },
  { header: "Total", align: "right" as const, width: 29 },
];

function lineRows(lines: DocLine[]) {
  return lines.map((l, i) => [
    String(i + 1), l.description, pdfNumber(l.quantity, Number(l.quantity) % 1 === 0 ? 0 : 3), pdfNumber(l.unit_price), `${pdfNumber(l.gst_rate, 0)}%`,
    pdfNumber(l.gst_amount ?? (Number(l.total) - Number(l.quantity) * Number(l.unit_price))), pdfNumber(l.total),
  ]);
}

function fail(error: { message: string } | null, what: string): never {
  throw new Error(error?.message ?? `${what} was not found.`);
}

type Header = { status: string; subtotal: number; gst_total: number; total: number; notes?: string | null };

function commonTotals(h: Header, extra: [string, string, ("bold" | "grand")?][] = []): PdfSpec["totals"] {
  return [["Subtotal", pdfMoney(h.subtotal)], ["GST", pdfMoney(h.gst_total)], ["Total", pdfMoney(h.total), "grand"], ...extra];
}

async function fetchDoc<T>(table: string, select: string, id: string, what: string): Promise<T> {
  const r = await supabase.from(table).select(select).eq("id", id).single();
  if (r.error || !r.data) fail(r.error, what);
  return r.data as unknown as T;
}
async function fetchLines(table: string, fk: string, id: string): Promise<DocLine[]> {
  const r = await supabase.from(table).select("description,quantity,unit_price,gst_rate,gst_amount,total").eq(fk, id).order("id");
  if (r.error) fail(r.error, "Document lines");
  return (r.data ?? []) as DocLine[];
}

export async function salesInvoicePdf(id: string): Promise<PdfSpec> {
  const h = await fetchDoc<Header & { invoice_number: number; invoice_date: string; due_date: string; reference: string | null; amount_paid: number; customer: ContactInfo; branch: { name: string } | null }>(
    "sales_invoices", `invoice_number,invoice_date,due_date,reference,status,subtotal,gst_total,total,amount_paid,notes,customer:contacts!customer_id(${CONTACT}),branch:branches!branch_id(name)`, id, "Invoice");
  const lines = await fetchLines("sales_invoice_lines", "invoice_id", id);
  const paid = Number(h.amount_paid ?? 0);
  const number = `INV-${pad(h.invoice_number)}`;
  const gst = !!getPdfCompany()?.gst_registered;
  return {
    title: gst ? "Sales Tax Invoice" : "Invoice", number, date: h.invoice_date, status: h.status,
    parties: [{ label: "Bill to", lines: partyLines(h.customer) }],
    meta: [["Invoice date", pdfDate(h.invoice_date)], ["Due date", pdfDate(h.due_date)], ["Reference", h.reference], ["Branch", h.branch?.name]],
    columns: lineColumns, rows: lineRows(lines),
    totals: commonTotals(h, paid > 0 ? [["Received", pdfMoney(paid)], ["Balance due", pdfMoney(Math.max(0, Number(h.total) - paid)), "bold"]] : []),
    amountInWords: Number(h.total), notes: h.notes ?? undefined, signatures: ["Prepared by", "Customer signature"], filename: number,
  };
}

export async function purchaseBillPdf(id: string): Promise<PdfSpec> {
  const h = await fetchDoc<Header & { bill_number: number; bill_date: string; due_date: string; supplier_reference: string | null; amount_paid: number; supplier: ContactInfo }>(
    "purchase_bills", `bill_number,bill_date,due_date,supplier_reference,status,subtotal,gst_total,total,amount_paid,notes,supplier:contacts!supplier_id(${CONTACT})`, id, "Bill");
  const lines = await fetchLines("purchase_bill_lines", "bill_id", id);
  const paid = Number(h.amount_paid ?? 0);
  const number = `BILL-${pad(h.bill_number)}`;
  return {
    title: "Purchase Bill", number, date: h.bill_date, status: h.status,
    parties: [{ label: "Supplier", lines: partyLines(h.supplier) }],
    meta: [["Bill date", pdfDate(h.bill_date)], ["Due date", pdfDate(h.due_date)], ["Supplier ref.", h.supplier_reference]],
    columns: lineColumns, rows: lineRows(lines),
    totals: commonTotals(h, paid > 0 ? [["Paid", pdfMoney(paid)], ["Balance payable", pdfMoney(Math.max(0, Number(h.total) - paid)), "bold"]] : []),
    amountInWords: Number(h.total), notes: h.notes ?? undefined, signatures: ["Prepared by", "Approved by"], filename: number,
  };
}

export async function salesCreditNotePdf(id: string): Promise<PdfSpec> {
  const h = await fetchDoc<Header & { credit_number: number; credit_date: string; reason: string | null; customer: ContactInfo; invoice: { invoice_number: number } | null }>(
    "sales_credit_notes", `credit_number,credit_date,reason,status,subtotal,gst_total,total,customer:contacts!customer_id(${CONTACT}),invoice:sales_invoices!invoice_id(invoice_number)`, id, "Credit note");
  const lines = await fetchLines("sales_credit_note_lines", "credit_note_id", id);
  const number = `CN-${pad(h.credit_number)}`;
  return {
    title: "Credit Note", number, date: h.credit_date, status: h.status,
    parties: [{ label: "Customer", lines: partyLines(h.customer) }],
    meta: [["Credit date", pdfDate(h.credit_date)], ["Against invoice", h.invoice ? `INV-${pad(h.invoice.invoice_number)}` : null], ["Reason", h.reason]],
    columns: lineColumns, rows: lineRows(lines), totals: commonTotals(h), amountInWords: Number(h.total), signatures: ["Prepared by", "Approved by"], filename: number,
  };
}

export async function purchaseDebitNotePdf(id: string): Promise<PdfSpec> {
  const h = await fetchDoc<Header & { debit_number: number; debit_date: string; reason: string | null; supplier: ContactInfo; bill: { bill_number: number } | null }>(
    "purchase_debit_notes", `debit_number,debit_date,reason,status,subtotal,gst_total,total,supplier:contacts!supplier_id(${CONTACT}),bill:purchase_bills!bill_id(bill_number)`, id, "Debit note");
  const lines = await fetchLines("purchase_debit_note_lines", "debit_note_id", id);
  const number = `DN-${pad(h.debit_number)}`;
  return {
    title: "Debit Note", number, date: h.debit_date, status: h.status,
    parties: [{ label: "Supplier", lines: partyLines(h.supplier) }],
    meta: [["Debit date", pdfDate(h.debit_date)], ["Against bill", h.bill ? `BILL-${pad(h.bill.bill_number)}` : null], ["Reason", h.reason]],
    columns: lineColumns, rows: lineRows(lines), totals: commonTotals(h), amountInWords: Number(h.total), signatures: ["Prepared by", "Approved by"], filename: number,
  };
}

export async function salesOrderPdf(id: string): Promise<PdfSpec> {
  const h = await fetchDoc<Header & { order_number: number; order_date: string; promised_date: string | null; customer_reference: string | null; customer: ContactInfo }>(
    "sales_orders", `order_number,order_date,promised_date,customer_reference,status,subtotal,gst_total,total,notes,customer:contacts!customer_id(${CONTACT})`, id, "Sales order");
  const lines = await fetchLines("sales_order_lines", "sales_order_id", id);
  const number = `SO-${pad(h.order_number)}`;
  return {
    title: "Sales Order", number, date: h.order_date, status: h.status,
    parties: [{ label: "Customer", lines: partyLines(h.customer) }],
    meta: [["Order date", pdfDate(h.order_date)], ["Promised date", pdfDate(h.promised_date)], ["Customer ref.", h.customer_reference]],
    columns: lineColumns, rows: lineRows(lines), totals: commonTotals(h), notes: h.notes ?? undefined, signatures: ["Prepared by", "Customer signature"], filename: number,
  };
}

export async function purchaseOrderPdf(id: string): Promise<PdfSpec> {
  const h = await fetchDoc<Header & { order_number: number; order_date: string; expected_date: string | null; supplier_reference: string | null; supplier: ContactInfo }>(
    "purchase_orders", `order_number,order_date,expected_date,supplier_reference,status,subtotal,gst_total,total,notes,supplier:contacts!supplier_id(${CONTACT})`, id, "Purchase order");
  const lines = await fetchLines("purchase_order_lines", "purchase_order_id", id);
  const number = `PO-${pad(h.order_number)}`;
  return {
    title: "Purchase Order", number, date: h.order_date, status: h.status,
    parties: [{ label: "Supplier", lines: partyLines(h.supplier) }],
    meta: [["Order date", pdfDate(h.order_date)], ["Expected", pdfDate(h.expected_date)], ["Supplier ref.", h.supplier_reference]],
    columns: lineColumns, rows: lineRows(lines), totals: commonTotals(h), notes: h.notes ?? undefined, signatures: ["Prepared by", "Authorised by"], filename: number,
  };
}

export async function salesQuotationPdf(id: string): Promise<PdfSpec> {
  const h = await fetchDoc<Header & { quotation_number: number; quotation_date: string; valid_until: string | null; customer: ContactInfo }>(
    "quotations", `quotation_number,quotation_date,valid_until,status,subtotal,gst_total,total,notes,customer:contacts!customer_id(${CONTACT})`, id, "Quotation");
  const lines = await fetchLines("quotation_lines", "quotation_id", id);
  const number = `QT-${pad(h.quotation_number)}`;
  return {
    title: "Quotation", number, date: h.quotation_date, status: h.status,
    parties: [{ label: "Prepared for", lines: partyLines(h.customer) }],
    meta: [["Quotation date", pdfDate(h.quotation_date)], ["Valid until", pdfDate(h.valid_until)]],
    columns: lineColumns, rows: lineRows(lines), totals: commonTotals(h), amountInWords: Number(h.total),
    notes: h.notes || "This quotation is subject to availability and the validity date shown above.", signatures: ["Prepared by", "Customer acceptance"], filename: number,
  };
}

export async function paymentVoucherPdf(id: string): Promise<PdfSpec> {
  const h = await fetchDoc<{ payment_number: number; direction: string; payment_date: string; amount: number; reference: string | null; notes: string | null; status: string; contact: ContactInfo; bank: { name: string } | null; invoice: { invoice_number: number } | null; bill: { bill_number: number } | null }>(
    "payments", `payment_number,direction,payment_date,amount,reference,notes,status,contact:contacts!contact_id(${CONTACT}),bank:bank_accounts!bank_account_id(name),invoice:sales_invoices!sales_invoice_id(invoice_number),bill:purchase_bills!purchase_bill_id(bill_number)`, id, "Payment");
  const receipt = h.direction === "receipt";
  const number = `PAY-${pad(h.payment_number)}`;
  const allocation = h.invoice ? `Against sales invoice INV-${pad(h.invoice.invoice_number)}` : h.bill ? `Against purchase bill BILL-${pad(h.bill.bill_number)}` : "Unallocated / advance";
  return {
    title: receipt ? "Receipt Voucher" : "Payment Voucher", number, date: h.payment_date, status: h.status,
    parties: [{ label: receipt ? "Received from" : "Paid to", lines: partyLines(h.contact) }],
    meta: [["Date", pdfDate(h.payment_date)], [receipt ? "Deposited to" : "Paid from", h.bank?.name ?? "Cash"], ["Reference", h.reference]],
    columns: [{ header: "Description" }, { header: "Amount", align: "right", width: 40 }],
    rows: [[`${allocation}${h.notes ? `\n${h.notes}` : ""}`, pdfMoney(h.amount)]],
    totals: [[receipt ? "Total received" : "Total paid", pdfMoney(h.amount), "grand"]], amountInWords: Number(h.amount),
    signatures: ["Prepared by", receipt ? "Received by" : "Paid to (signature)"], filename: number,
  };
}

export async function journalEntryPdf(id: string): Promise<PdfSpec> {
  const h = await fetchDoc<{ entry_number: number; entry_date: string; reference: string | null; description: string | null; status: string }>(
    "journal_entries", "entry_number,entry_date,reference,description,status", id, "Journal entry");
  const r = await supabase.from("journal_lines").select("description,debit,credit,account:accounts!account_id(code,name)").eq("entry_id", id).order("id");
  if (r.error) fail(r.error, "Journal lines");
  const lines = (r.data ?? []) as unknown as { description: string | null; debit: number; credit: number; account: { code: string; name: string } | null }[];
  const debit = lines.reduce((n, l) => n + Number(l.debit || 0), 0), credit = lines.reduce((n, l) => n + Number(l.credit || 0), 0);
  const number = `JV-${pad(h.entry_number)}`;
  return {
    title: "Journal Voucher", number, date: h.entry_date, status: h.status,
    meta: [["Date", pdfDate(h.entry_date)], ["Reference", h.reference], ["Narration", h.description]],
    columns: [{ header: "Code", width: 20 }, { header: "Account" }, { header: "Description" }, { header: "Debit", align: "right", width: 30 }, { header: "Credit", align: "right", width: 30 }],
    rows: [...lines.map((l) => [l.account?.code ?? "", l.account?.name ?? "", l.description ?? "", Number(l.debit) ? pdfNumber(l.debit) : "", Number(l.credit) ? pdfNumber(l.credit) : ""]), ["Total", "", "", pdfNumber(debit), pdfNumber(credit)]],
    signatures: ["Prepared by", "Approved by"], filename: number,
  };
}
