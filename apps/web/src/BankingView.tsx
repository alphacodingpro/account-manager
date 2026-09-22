import { useEffect, useMemo, useState } from "react";
import { Building2, Landmark, Plus, RotateCcw, Trash2, WalletCards, X } from "lucide-react";
import { supabase } from "./lib/supabase";

type Branch = { id: string; name: string; active: boolean };
type Account = { id: string; code: string; name: string; type: string; active: boolean };
type Contact = { id: string; name: string; kind: "customer" | "supplier" | "both" };
type BankAccount = { id: string; name: string; bank_name: string | null; account_number: string | null; iban: string | null; ledger_account_id: string; active: boolean };
type Document = { id: string; number: number; contact_id: string; total: number; amount_paid: number };
type Payment = { id: string; payment_number: number; payment_date: string; direction: "receipt" | "payment"; amount: number; reference: string | null; status: string; contacts: { name: string } | null; bank_accounts: { name: string } | null; cash: { name: string } | null };

const pkr = new Intl.NumberFormat("en-PK", { style: "currency", currency: "PKR" });
const today = new Date().toISOString().slice(0, 10);

export default function BankingView({ companyId, branches, accounts }: { companyId: string; branches: Branch[]; accounts: Account[] }) {
  const [banks, setBanks] = useState<BankAccount[]>([]);
  const [contacts, setContacts] = useState<Contact[]>([]);
  const [invoices, setInvoices] = useState<Document[]>([]);
  const [bills, setBills] = useState<Document[]>([]);
  const [payments, setPayments] = useState<Payment[]>([]);
  const [bankOpen, setBankOpen] = useState(false);
  const [entryOpen, setEntryOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [bank, setBank] = useState({ name: "", bankName: "", accountNumber: "", iban: "", ledgerAccountId: "", branchId: "" });
  const [entry, setEntry] = useState({ direction: "receipt" as "receipt" | "payment", branchId: "", contactId: "", mode: "bank", moneyAccountId: "", documentId: "", date: today, amount: "", reference: "", notes: "" });
  const assetAccounts = accounts.filter((a) => a.active && a.type === "asset");
  const filteredContacts = contacts.filter((c) => entry.direction === "receipt" ? c.kind !== "supplier" : c.kind !== "customer");
  const documents = entry.direction === "receipt" ? invoices : bills;
  const filteredDocuments = documents.filter((d) => !entry.contactId || d.contact_id === entry.contactId);
  const selectedDocument = documents.find((d) => d.id === entry.documentId);
  const outstanding = selectedDocument ? Number(selectedDocument.total) - Number(selectedDocument.amount_paid) : 0;
  const totals = useMemo(() => payments.filter((p) => p.status === "posted").reduce((a, p) => ({ ...a, [p.direction]: a[p.direction] + Number(p.amount) }), { receipt: 0, payment: 0 }), [payments]);

  async function load() {
    const [bankResult, contactResult, invoiceResult, billResult, paymentResult] = await Promise.all([
      supabase.from("bank_accounts").select("id,name,bank_name,account_number,iban,ledger_account_id,active").eq("company_id", companyId).order("name"),
      supabase.from("contacts").select("id,name,kind").eq("company_id", companyId).eq("active", true).order("name"),
      supabase.from("sales_invoices").select("id,invoice_number,customer_id,total,amount_paid").eq("company_id", companyId).in("status", ["posted", "paid"]).order("invoice_date", { ascending: false }),
      supabase.from("purchase_bills").select("id,bill_number,supplier_id,total,amount_paid").eq("company_id", companyId).in("status", ["posted", "part_paid", "paid"]).order("bill_date", { ascending: false }),
      supabase.from("payments").select("id,payment_number,payment_date,direction,amount,reference,status,contacts(name),bank_accounts(name),cash:accounts(name)").eq("company_id", companyId).order("payment_date", { ascending: false }).limit(50),
    ]);
    const error = bankResult.error || contactResult.error || invoiceResult.error || billResult.error || paymentResult.error;
    if (error) return setMessage(error.message);
    setBanks((bankResult.data ?? []) as BankAccount[]);
    setContacts((contactResult.data ?? []) as Contact[]);
    setInvoices((invoiceResult.data ?? []).map((x) => ({ id: x.id, number: x.invoice_number, contact_id: x.customer_id, total: Number(x.total), amount_paid: Number(x.amount_paid) })));
    setBills((billResult.data ?? []).map((x) => ({ id: x.id, number: x.bill_number, contact_id: x.supplier_id, total: Number(x.total), amount_paid: Number(x.amount_paid) })));
    setPayments((paymentResult.data ?? []) as unknown as Payment[]);
    setEntry((old) => ({ ...old, branchId: old.branchId || branches.find((b) => b.active)?.id || "" }));
  }

  useEffect(() => { load(); }, [companyId]);

  function resetEntry(direction: "receipt" | "payment" = entry.direction) {
    setEntry({ direction, branchId: branches.find((b) => b.active)?.id || "", contactId: "", mode: "bank", moneyAccountId: "", documentId: "", date: today, amount: "", reference: "", notes: "" });
  }

  async function addBankAccount(e: React.FormEvent) {
    e.preventDefault(); setBusy(true); setMessage("");
    const result = await supabase.from("bank_accounts").insert({ company_id: companyId, branch_id: bank.branchId || null, ledger_account_id: bank.ledgerAccountId, name: bank.name.trim(), bank_name: bank.bankName.trim() || null, account_number: bank.accountNumber.trim() || null, iban: bank.iban.replaceAll(" ", "").toUpperCase() || null });
    if (result.error) setMessage(result.error.message); else { setMessage("Bank account created successfully."); setBankOpen(false); setBank({ name: "", bankName: "", accountNumber: "", iban: "", ledgerAccountId: "", branchId: "" }); await load(); }
    setBusy(false);
  }

  async function savePayment(shouldPost: boolean) {
    setMessage("");
    if (!entry.branchId || !entry.contactId || !entry.moneyAccountId || Number(entry.amount) <= 0) return setMessage("Branch, contact, money account and a valid amount are required.");
    if (entry.documentId && Number(entry.amount) > outstanding) return setMessage("Amount cannot exceed the selected document balance.");
    setBusy(true);
    try {
      const { data: auth } = await supabase.auth.getUser(); if (!auth.user) throw new Error("Session expired.");
      const created = await supabase.from("payments").insert({ company_id: companyId, branch_id: entry.branchId, contact_id: entry.contactId, bank_account_id: entry.mode === "bank" ? entry.moneyAccountId : null, cash_account_id: entry.mode === "cash" ? entry.moneyAccountId : null, direction: entry.direction, payment_date: entry.date, amount: Number(entry.amount), reference: entry.reference.trim() || null, notes: entry.notes.trim() || null, sales_invoice_id: entry.direction === "receipt" ? entry.documentId || null : null, purchase_bill_id: entry.direction === "payment" ? entry.documentId || null : null, created_by: auth.user.id }).select("id").single();
      if (created.error) throw created.error;
      if (shouldPost) { const posted = await supabase.rpc("post_payment", { target_payment: created.data.id }); if (posted.error) { await supabase.from("payments").delete().eq("id", created.data.id).eq("status", "draft"); throw posted.error; } }
      setMessage(shouldPost ? "Transaction posted to the ledger." : "Transaction saved as draft."); setEntryOpen(false); resetEntry(); await load();
    } catch (error) { setMessage(error instanceof Error ? error.message : "Unable to save transaction."); }
    finally { setBusy(false); }
  }

  async function postDraft(id: string) {
    if (!confirm("Post this draft transaction? It will become immutable.")) return;
    const result = await supabase.rpc("post_payment", { target_payment: id });
    if (result.error) setMessage(result.error.message); else { setMessage("Draft posted successfully."); await load(); }
  }

  async function removeOrReverse(payment: Payment) {
    const draft = payment.status === "draft";
    if (!confirm(draft ? "Delete this draft transaction?" : "Reverse this posted transaction with an opposite journal entry?")) return;
    const result = draft ? await supabase.from("payments").delete().eq("id", payment.id).eq("status", "draft") : await supabase.rpc("void_payment", { target_payment: payment.id, target_reason: "Reversed from Banking" });
    if (result.error) setMessage(result.error.message); else { setMessage(draft ? "Draft deleted." : "Payment reversed and allocation restored."); await load(); }
  }

  return <div className="accounting-stack">
    <div className="bank-metrics"><article><Landmark/><span>Active bank accounts</span><b>{banks.filter((b) => b.active).length}</b></article><article><Plus/><span>Posted receipts</span><b>{pkr.format(totals.receipt)}</b></article><article><WalletCards/><span>Posted payments</span><b>{pkr.format(totals.payment)}</b></article></div>
    <article className="panel data-panel"><div className="panel-head"><div><h3>Banking & cash</h3><p>Auditable customer receipts and supplier payments</p></div><div className="toolbar"><button className="outline" onClick={() => setBankOpen((v) => !v)}>{bankOpen ? <X size={16}/> : <Building2 size={16}/>} Bank account</button><button className="primary small-button" onClick={() => { resetEntry(); setEntryOpen((v) => !v); }}><Plus size={16}/> New transaction</button></div></div>
      {message && <p className={message.includes("success") || message.includes("posted") || message.includes("reversed") || message.includes("saved") || message.includes("deleted") ? "notice" : "alert"}>{message}</p>}
      {bankOpen && <form className="bank-form" onSubmit={addBankAccount}><label>Display name<input value={bank.name} onChange={(e) => setBank({ ...bank, name: e.target.value })} placeholder="Meezan Current" required/></label><label>Bank name<input value={bank.bankName} onChange={(e) => setBank({ ...bank, bankName: e.target.value })}/></label><label>Account number<input value={bank.accountNumber} onChange={(e) => setBank({ ...bank, accountNumber: e.target.value })}/></label><label>IBAN<input value={bank.iban} onChange={(e) => setBank({ ...bank, iban: e.target.value })}/></label><label>Ledger account<select value={bank.ledgerAccountId} onChange={(e) => setBank({ ...bank, ledgerAccountId: e.target.value })} required><option value="">Select asset account</option>{assetAccounts.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select></label><label>Branch<select value={bank.branchId} onChange={(e) => setBank({ ...bank, branchId: e.target.value })}><option value="">Company-wide</option>{branches.filter((b) => b.active).map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}</select></label><button className="primary" disabled={busy}>Save bank</button></form>}
      {entryOpen && <form className="bank-form transaction-form" onSubmit={(e) => { e.preventDefault(); savePayment(true); }}><label>Type<select value={entry.direction} onChange={(e) => { const direction = e.target.value as "receipt" | "payment"; resetEntry(direction); }}><option value="receipt">Customer receipt</option><option value="payment">Supplier payment</option></select></label><label>Branch<select value={entry.branchId} onChange={(e) => setEntry({ ...entry, branchId: e.target.value })} required><option value="">Select</option>{branches.filter((b) => b.active).map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}</select></label><label>{entry.direction === "receipt" ? "Customer" : "Supplier"}<select value={entry.contactId} onChange={(e) => setEntry({ ...entry, contactId: e.target.value, documentId: "" })} required><option value="">Select</option>{filteredContacts.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></label><label>Pay through<select value={entry.mode} onChange={(e) => setEntry({ ...entry, mode: e.target.value, moneyAccountId: "" })}><option value="bank">Bank</option><option value="cash">Cash ledger</option></select></label><label>{entry.mode === "bank" ? "Bank account" : "Cash account"}<select value={entry.moneyAccountId} onChange={(e) => setEntry({ ...entry, moneyAccountId: e.target.value })} required><option value="">Select</option>{(entry.mode === "bank" ? banks.filter((b) => b.active) : assetAccounts).map((x) => <option key={x.id} value={x.id}>{"code" in x ? `${x.code} · ${x.name}` : x.name}</option>)}</select></label><label>Allocate to<select value={entry.documentId} onChange={(e) => { const id = e.target.value; const doc = documents.find((d) => d.id === id); setEntry({ ...entry, documentId: id, amount: doc ? String(Number(doc.total) - Number(doc.amount_paid)) : entry.amount }); }}><option value="">Unallocated / advance</option>{filteredDocuments.filter((d) => d.total > d.amount_paid).map((d) => <option key={d.id} value={d.id}>{entry.direction === "receipt" ? "INV" : "BILL"}-{String(d.number).padStart(6, "0")} · {pkr.format(d.total - d.amount_paid)}</option>)}</select></label><label>Date<input type="date" value={entry.date} onChange={(e) => setEntry({ ...entry, date: e.target.value })} required/></label><label>Amount<input type="number" min="0.01" max={entry.documentId ? outstanding : undefined} step="0.01" value={entry.amount} onChange={(e) => setEntry({ ...entry, amount: e.target.value })} required/></label><label>Reference<input value={entry.reference} onChange={(e) => setEntry({ ...entry, reference: e.target.value })} placeholder="Cheque / transfer ref"/></label><label className="wide">Notes<input value={entry.notes} onChange={(e) => setEntry({ ...entry, notes: e.target.value })}/></label><div className="form-actions wide"><button type="button" className="outline" disabled={busy} onClick={() => savePayment(false)}>Save draft</button><button className="primary" disabled={busy}>{busy ? "Posting..." : "Post transaction"}</button></div></form>}
      <div className="bank-table"><div className="bank-row data-heading"><span>No.</span><span>Date</span><span>Type</span><span>Contact</span><span>Account</span><span>Reference</span><span>Amount</span><span>Status</span><span>Actions</span></div>{payments.map((p) => <div className="bank-row" key={p.id}><span className="code">PAY-{String(p.payment_number).padStart(6, "0")}</span><span>{p.payment_date}</span><span className="capitalize">{p.direction}</span><span>{p.contacts?.name ?? "—"}</span><span>{p.bank_accounts?.name ?? p.cash?.name ?? "—"}</span><span>{p.reference ?? "—"}</span><b>{pkr.format(Number(p.amount))}</b><span className="status">{p.status}</span><span className="row-actions">{p.status === "draft" && <button title="Post draft" onClick={() => postDraft(p.id)}><Plus size={14}/></button>}{["draft", "posted"].includes(p.status) && <button className="danger" title={p.status === "draft" ? "Delete draft" : "Reverse payment"} onClick={() => removeOrReverse(p)}>{p.status === "draft" ? <Trash2 size={14}/> : <RotateCcw size={14}/>}</button>}</span></div>)}</div>
    </article>
  </div>;
}
