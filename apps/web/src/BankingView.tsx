import { listRecords } from "./lib/listRecords";
import { ListSearch, matchesRecord, RecordView } from "./RecordTools";
import { useEffect, useMemo, useState } from "react";
import {
  Eye,
  Pencil,
  Building2,
  CheckCircle2,
  Landmark,
  Link2,
  Plus,
  RotateCcw,
  Trash2,
  Unlink,
  Upload,
  WalletCards,
  X,
} from "lucide-react";
import { supabase } from "./lib/supabase";
import { dayDistance, parseStatementCsv } from "./lib/bankCsv";
import Modal, { statusClass } from "./Modal";

type Branch = { id: string; name: string; active: boolean };
type Account = { id: string; code: string; name: string; type: string; active: boolean };
type Contact = { id: string; name: string; kind: "customer" | "supplier" | "both" };
type BankAccount = { id: string; name: string; bank_name: string | null; account_number: string | null; iban: string | null; ledger_account_id: string; active: boolean };
type Document = { id: string; number: number; contact_id: string; total: number; amount_paid: number };
type Payment = { branch_id:string; contact_id:string; bank_account_id:string|null; cash_account_id:string|null; sales_invoice_id:string|null; purchase_bill_id:string|null; notes:string|null; id: string; payment_number: number; payment_date: string; direction: "receipt" | "payment"; amount: number; reference: string | null; status: string; contacts: { name: string } | null; bank_accounts: { name: string } | null; cash: { name: string } | null };
type MatchPayment = Pick<Payment, "id" | "payment_number" | "payment_date" | "direction" | "amount" | "reference">;
type StatementLine = { id: string; transaction_date: string; description: string | null; reference: string | null; debit: number; credit: number; matched_payment_id: string | null; reconciled: boolean };

const pkr = new Intl.NumberFormat("en-PK", { style: "currency", currency: "PKR" });
const today = new Date().toISOString().slice(0, 10);

export default function BankingView({ companyId, branches, accounts, section = "transactions" }: { companyId: string; branches: Branch[]; accounts: Account[]; section?: "accounts" | "transactions" | "receipts" | "payments" | "reconciliation" }) {
  const transactionSection = ["transactions", "receipts", "payments"].includes(section);
  const pageDirection = section === "receipts" ? "receipt" : section === "payments" ? "payment" : undefined;
  const pageTitle = section === "receipts" ? "Receipts" : section === "payments" ? "Payments" : "Receipts & payments";
  const [toolsQuery,setToolsQuery]=useState("");
  const [editingPayment, setEditingPayment] = useState("");
  const [viewingPayment, setViewingPayment] = useState<Payment|null>(null);
  const [search, setSearch] = useState("");
  const [banks, setBanks] = useState<BankAccount[]>([]);
  const [contacts, setContacts] = useState<Contact[]>([]);
  const [invoices, setInvoices] = useState<Document[]>([]);
  const [bills, setBills] = useState<Document[]>([]);
  const [payments, setPayments] = useState<Payment[]>([]);
  const [statementLines, setStatementLines] = useState<StatementLine[]>([]);
  const [matchPayments, setMatchPayments] = useState<MatchPayment[]>([]);
  const [selectedMatches, setSelectedMatches] = useState<Record<string, string>>({});
  const [selectedBank, setSelectedBank] = useState("");
  const [bankOpen, setBankOpen] = useState(false);
  const [entryOpen, setEntryOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [bank, setBank] = useState({ name: "", bankName: "", accountNumber: "", iban: "", ledgerAccountId: "", branchId: "" });
  const [entry, setEntry] = useState({ direction: (pageDirection || "receipt") as "receipt" | "payment", branchId: "", contactId: "", mode: "bank", moneyAccountId: "", documentId: "", date: today, amount: "", reference: "", notes: "" });
  const assetAccounts = accounts.filter((a) => a.active && a.type === "asset");
  const filteredContacts = contacts.filter((c) => entry.direction === "receipt" ? c.kind !== "supplier" : c.kind !== "customer");
  const documents = entry.direction === "receipt" ? invoices : bills;
  const filteredDocuments = documents.filter((d) => !entry.contactId || d.contact_id === entry.contactId);
  const selectedDocument = documents.find((d) => d.id === entry.documentId);
  const outstanding = selectedDocument ? Number(selectedDocument.total) - Number(selectedDocument.amount_paid) : 0;
  const totals = useMemo(() => payments.filter((p) => p.status === "posted").reduce((a, p) => ({ ...a, [p.direction]: a[p.direction] + Number(p.amount) }), { receipt: 0, payment: 0 }), [payments]);
  const reconciledCount = statementLines.filter((line) => line.reconciled).length;

  const visiblePayments = payments.filter(p => (!pageDirection || p.direction === pageDirection) && search.trim().toLowerCase().split(/\s+/).filter(Boolean).every(term => [p.payment_number,`PAY-${String(p.payment_number).padStart(6,"0")}`,p.payment_date,p.direction,p.contacts?.name,p.bank_accounts?.name,p.cash?.name,p.reference,p.status,p.amount,pkr.format(Number(p.amount))].join(" ").toLowerCase().includes(term)));
  async function loadPaymentList() {
    const data:Payment[]=[];
    for(let offset=0;;offset+=500) {
      let query=supabase.from("payments").select("id,branch_id,contact_id,bank_account_id,cash_account_id,sales_invoice_id,purchase_bill_id,notes,payment_number,payment_date,direction,amount,reference,status,contacts(name),bank_accounts(name),cash:accounts(name)").eq("company_id",companyId);
      if(pageDirection) query=query.eq("direction",pageDirection);
      const result=await query.order("payment_date",{ascending:false}).order("id").range(offset,offset+499);
      if(result.error)return {data:null,error:result.error};
      data.push(...(result.data??[]) as unknown as Payment[]); if((result.data??[]).length<500)break;
    }
    return {data,error:null};
  }
  async function load() {
    const [bankResult, contactResult, invoiceResult, billResult, paymentResult] = await Promise.all([
      listRecords(supabase.from("bank_accounts").select("id,name,bank_name,account_number,iban,ledger_account_id,active").eq("company_id", companyId).order("name").order("id")),
      supabase.from("contacts").select("id,name,kind").eq("company_id", companyId).eq("active", true).order("name"),
      supabase.from("sales_invoices").select("id,invoice_number,customer_id,total,amount_paid").eq("company_id", companyId).in("status", ["posted", "paid"]).order("invoice_date", { ascending: false }),
      supabase.from("purchase_bills").select("id,bill_number,supplier_id,total,amount_paid").eq("company_id", companyId).in("status", ["posted", "part_paid", "paid"]).order("bill_date", { ascending: false }),
      loadPaymentList(),
    ]);
    const error = bankResult.error || contactResult.error || invoiceResult.error || billResult.error || paymentResult.error;
    if (error) return setMessage(error.message);
    const loadedBanks = (bankResult.data ?? []) as BankAccount[];
    setBanks(loadedBanks); setContacts((contactResult.data ?? []) as Contact[]);
    setInvoices((invoiceResult.data ?? []).map((x) => ({ id: x.id, number: x.invoice_number, contact_id: x.customer_id, total: Number(x.total), amount_paid: Number(x.amount_paid) })));
    setBills((billResult.data ?? []).map((x) => ({ id: x.id, number: x.bill_number, contact_id: x.supplier_id, total: Number(x.total), amount_paid: Number(x.amount_paid) })));
    setPayments((paymentResult.data ?? []) as unknown as Payment[]);
    setEntry((old) => ({ ...old, branchId: old.branchId || branches.find((b) => b.active)?.id || "" }));
    setSelectedBank((old) => loadedBanks.some((b) => b.id === old && b.active) ? old : loadedBanks.find((b) => b.active)?.id || "");
  }

  async function loadReconciliation(bankId = selectedBank) {
    if (!bankId) { setStatementLines([]); setMatchPayments([]); return; }
    const [linesResult, paymentsResult] = await Promise.all([
      listRecords(supabase.from("bank_statement_lines").select("id,transaction_date,description,reference,debit,credit,matched_payment_id,reconciled").eq("bank_account_id", bankId).order("transaction_date", { ascending: false }).order("id")),
      listRecords(supabase.from("payments").select("id,payment_number,payment_date,direction,amount,reference").eq("company_id", companyId).eq("bank_account_id", bankId).eq("status", "posted").order("payment_date", { ascending: false }).order("id")),
    ]);
    const error = linesResult.error || paymentsResult.error;
    if (error) return setMessage(error.message);
    const lines = (linesResult.data ?? []) as StatementLine[];
    const candidates = (paymentsResult.data ?? []) as MatchPayment[];
    setStatementLines(lines); setMatchPayments(candidates);
    const used = new Set(lines.filter((l) => l.reconciled && l.matched_payment_id).map((l) => l.matched_payment_id));
    const suggestions: Record<string, string> = {};
    for (const line of lines.filter((l) => !l.reconciled)) {
      const direction = Number(line.credit) > 0 ? "receipt" : "payment";
      const amount = Number(line.credit) > 0 ? Number(line.credit) : Number(line.debit);
      const possible = candidates.filter((p) => !used.has(p.id) && p.direction === direction && Number(p.amount) === amount && dayDistance(p.payment_date, line.transaction_date) <= 7).sort((a, b) => dayDistance(a.payment_date, line.transaction_date) - dayDistance(b.payment_date, line.transaction_date));
      if (possible[0]) suggestions[line.id] = possible[0].id;
    }
    setSelectedMatches(suggestions);
  }

  useEffect(() => { load(); }, [companyId]);
  useEffect(() => { loadReconciliation(selectedBank); }, [selectedBank]);

  function resetEntry(direction: "receipt" | "payment" = entry.direction) {
    setEditingPayment("");
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
    if (!entry.branchId || !entry.contactId || !entry.moneyAccountId || (!Number.isFinite(Number(entry.amount)) || Number(entry.amount) <= 0 || !/^\d+(\.\d{1,2})?$/.test(entry.amount))) return setMessage("Branch, contact, money account and a valid amount are required.");
    if (entry.documentId && Number(entry.amount) > outstanding) return setMessage("Amount cannot exceed the selected document balance.");
    setBusy(true);
    try {
      const { data: auth } = await supabase.auth.getUser(); if (!auth.user) throw new Error("Session expired.");
      const values = { company_id: companyId, branch_id: entry.branchId, contact_id: entry.contactId, bank_account_id: entry.mode === "bank" ? entry.moneyAccountId : null, cash_account_id: entry.mode === "cash" ? entry.moneyAccountId : null, direction: entry.direction, payment_date: entry.date, amount: Number(entry.amount), reference: entry.reference.trim() || null, notes: entry.notes.trim() || null, sales_invoice_id: entry.direction === "receipt" ? entry.documentId || null : null, purchase_bill_id: entry.direction === "payment" ? entry.documentId || null : null };
      const created = editingPayment ? await supabase.from("payments").update(values).eq("company_id", companyId).eq("id", editingPayment).eq("status", "draft").select("id").single() : await supabase.from("payments").insert({...values,created_by:auth.user.id}).select("id").single();
      if (created.error) throw created.error;
      if (shouldPost) { const posted = await supabase.rpc("post_payment", { target_payment: created.data.id }); if (posted.error) { await load(); throw new Error(`${posted.error.message} The saved draft is retained for review.`); } }

      setMessage(shouldPost ? "Transaction posted to the ledger." : "Transaction saved as draft."); setEntryOpen(false); resetEntry(); await load(); await loadReconciliation();
    } catch (error) { setMessage(error instanceof Error ? error.message : (error as {message?:string}).message || "Unable to save transaction."); }
    finally { setBusy(false); }
  }

  function editPayment(payment: Payment) {
    if (payment.status !== "draft") return;
    setEditingPayment(payment.id);setMessage("");setEntryOpen(true);
    setEntry({direction:payment.direction,branchId:payment.branch_id,contactId:payment.contact_id,mode:payment.bank_account_id?"bank":"cash",moneyAccountId:payment.bank_account_id||payment.cash_account_id||"",documentId:payment.sales_invoice_id||payment.purchase_bill_id||"",date:payment.payment_date,amount:String(payment.amount),reference:payment.reference||"",notes:payment.notes||""});
  }
  async function postDraft(id: string) {
    if (!confirm("Post this draft transaction? It will become immutable.")) return;
    const result = await supabase.rpc("post_payment", { target_payment: id });
    if (result.error) setMessage(result.error.message); else { setMessage("Draft posted successfully."); await load(); await loadReconciliation(); }
  }

  async function removeOrReverse(payment: Payment) {
    const draft = payment.status === "draft";
    if (!confirm(draft ? "Delete this draft transaction?" : "Reverse this posted transaction with an opposite journal entry?")) return;
    const result = draft ? await supabase.from("payments").delete().eq("id", payment.id).eq("status", "draft") : await supabase.rpc("void_payment", { target_payment: payment.id, target_reason: "Reversed from Banking" });
    if (result.error) setMessage(result.error.message); else { setMessage(draft ? "Draft deleted." : "Payment reversed and allocation restored."); await load(); await loadReconciliation(); }
  }

  async function importStatement(file: File) {
    if (!selectedBank) return setMessage("Select a bank account before importing.");
    setBusy(true); setMessage("");
    try {
      const lines = parseStatementCsv(await file.text());
      const result = await supabase.rpc("import_bank_statement", { target_bank: selectedBank, target_file_name: file.name, target_lines: lines });
      if (result.error) throw result.error;
      const summary = result.data as { inserted_count: number; duplicate_count: number };
      setMessage(`Statement imported: ${summary.inserted_count} new, ${summary.duplicate_count} duplicate rows skipped.`);
      await loadReconciliation();
    } catch (error) { setMessage(error instanceof Error ? error.message : "Unable to import statement."); }
    finally { setBusy(false); }
  }

  function candidatesFor(line: StatementLine) {
    const used = new Set(statementLines.filter((l) => l.id !== line.id && l.reconciled && l.matched_payment_id).map((l) => l.matched_payment_id));
    const direction = Number(line.credit) > 0 ? "receipt" : "payment";
    const amount = Number(line.credit) > 0 ? Number(line.credit) : Number(line.debit);
    return matchPayments.filter((p) => !used.has(p.id) && p.direction === direction && Number(p.amount) === amount).sort((a, b) => dayDistance(a.payment_date, line.transaction_date) - dayDistance(b.payment_date, line.transaction_date));
  }

  async function reconcile(lineId: string) {
    const paymentId = selectedMatches[lineId]; if (!paymentId) return setMessage("Select a matching posted payment.");
    setBusy(true);
    const result = await supabase.rpc("reconcile_bank_statement_line", { target_line: lineId, target_payment: paymentId, target_reason: "Matched in Banking" });
    if (result.error) setMessage(result.error.message); else { setMessage("Statement line reconciled successfully."); await loadReconciliation(); }
    setBusy(false);
  }

  async function unreconcile(lineId: string) {
    const reason = prompt("Reason for unreconciling this line:")?.trim(); if (!reason) return;
    setBusy(true);
    const result = await supabase.rpc("unreconcile_bank_statement_line", { target_line: lineId, target_reason: reason });
    if (result.error) setMessage(result.error.message); else { setMessage("Statement line unreconciled with audit history preserved."); await loadReconciliation(); }
    setBusy(false);
  }

  return <div className="accounting-stack">{["accounts","reconciliation"].includes(section)&&<ListSearch value={toolsQuery} onChange={setToolsQuery} records={section==="accounts"?banks:statementLines}/>}
    <div className="bank-metrics"><article><Landmark/><span>Active bank accounts</span><b>{banks.filter((b) => b.active).length}</b></article>{pageDirection !== "payment" && <article><Plus/><span>Posted receipts</span><b>{pkr.format(totals.receipt)}</b></article>}{pageDirection !== "receipt" && <article><WalletCards/><span>Posted payments</span><b>{pkr.format(totals.payment)}</b></article>}</div>
    {message && <p role="status" className="notice">{message}</p>}
    {section !== "reconciliation" && <article className="panel data-panel"><div className="panel-head"><div><h3>{section === "accounts" ? "Bank accounts" : pageTitle}</h3><p>{section === "accounts" ? "Manage bank accounts and their ledger links" : "Auditable customer receipts and supplier payments"}</p></div><div className="toolbar">{section === "accounts" ? <button className="primary small-button" onClick={() => { setMessage(""); setBankOpen(true); }}><Building2 size={16}/> New bank account</button> : <button className="primary small-button" onClick={() => { resetEntry(pageDirection || entry.direction); setMessage(""); setEntryOpen(true); }}><Plus size={16}/> {pageDirection === "receipt" ? "New receipt" : pageDirection === "payment" ? "New payment" : "New transaction"}</button>}</div></div>
      {section === "accounts" && bankOpen&&<Modal onClose={()=>setBankOpen(false)} title={"New bank account"} size="md" subtitle={"Link the bank account to an asset ledger account so payments post correctly."} message={message}><form className="bank-form" onSubmit={addBankAccount}><label>Display name<input value={bank.name} onChange={(e) => setBank({ ...bank, name: e.target.value })} placeholder="Meezan Current" required/></label><label>Bank name<input value={bank.bankName} onChange={(e) => setBank({ ...bank, bankName: e.target.value })}/></label><label>Account number<input value={bank.accountNumber} onChange={(e) => setBank({ ...bank, accountNumber: e.target.value })}/></label><label>IBAN<input value={bank.iban} onChange={(e) => setBank({ ...bank, iban: e.target.value })}/></label><label>Ledger account<select value={bank.ledgerAccountId} onChange={(e) => setBank({ ...bank, ledgerAccountId: e.target.value })} required><option value="">Select asset account</option>{assetAccounts.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select></label><label>Branch<select value={bank.branchId} onChange={(e) => setBank({ ...bank, branchId: e.target.value })}><option value="">Company-wide</option>{branches.filter((b) => b.active).map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}</select></label><div className="form-actions wide"><button type="button" className="outline" disabled={busy} onClick={()=>setBankOpen(false)}>Cancel</button><button className="primary" disabled={busy}>Save bank</button></div></form></Modal>}
      {transactionSection && entryOpen&&<Modal onClose={()=>{setEntryOpen(false);resetEntry();}} title={editingPayment?"Edit draft transaction":pageDirection==="receipt"?"New receipt":pageDirection==="payment"?"New payment":"New transaction"} size="lg" subtitle={"Allocate to an open invoice or bill, or keep it as an unallocated advance."} message={message}><form className="bank-form transaction-form" onSubmit={(e) => { e.preventDefault(); savePayment(true); }}><label>Type<select disabled={!!pageDirection} value={entry.direction} onChange={(e) => resetEntry(e.target.value as "receipt" | "payment")}><option value="receipt">Customer receipt</option><option value="payment">Supplier payment</option></select></label><label>Branch<select value={entry.branchId} onChange={(e) => setEntry({ ...entry, branchId: e.target.value })} required><option value="">Select</option>{branches.filter((b) => b.active).map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}</select></label><label>{entry.direction === "receipt" ? "Customer" : "Supplier"}<select value={entry.contactId} onChange={(e) => setEntry({ ...entry, contactId: e.target.value, documentId: "" })} required><option value="">Select</option>{filteredContacts.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></label><label>Pay through<select value={entry.mode} onChange={(e) => setEntry({ ...entry, mode: e.target.value, moneyAccountId: "" })}><option value="bank">Bank</option><option value="cash">Cash ledger</option></select></label><label>{entry.mode === "bank" ? "Bank account" : "Cash account"}<select value={entry.moneyAccountId} onChange={(e) => setEntry({ ...entry, moneyAccountId: e.target.value })} required><option value="">Select</option>{(entry.mode === "bank" ? banks.filter((b) => b.active) : assetAccounts).map((x) => <option key={x.id} value={x.id}>{"code" in x ? `${x.code} · ${x.name}` : x.name}</option>)}</select></label><label>Allocate to<select value={entry.documentId} onChange={(e) => { const id = e.target.value; const doc = documents.find((d) => d.id === id); setEntry({ ...entry, documentId: id, amount: doc ? String(Number(doc.total) - Number(doc.amount_paid)) : entry.amount }); }}><option value="">Unallocated / advance</option>{filteredDocuments.filter((d) => d.total > d.amount_paid).map((d) => <option key={d.id} value={d.id}>{entry.direction === "receipt" ? "INV" : "BILL"}-{String(d.number).padStart(6, "0")} · {pkr.format(d.total - d.amount_paid)}</option>)}</select></label><label>Date<input type="date" value={entry.date} onChange={(e) => setEntry({ ...entry, date: e.target.value })} required/></label><label>Amount<input type="number" min="0.01" max={entry.documentId ? outstanding : undefined} step="0.01" value={entry.amount} onChange={(e) => setEntry({ ...entry, amount: e.target.value })} required/></label><label>Reference<input value={entry.reference} onChange={(e) => setEntry({ ...entry, reference: e.target.value })} placeholder="Cheque / transfer ref"/></label><label className="wide">Notes<input value={entry.notes} onChange={(e) => setEntry({ ...entry, notes: e.target.value })}/></label><div className="form-actions wide"><button type="button" className="outline" disabled={busy} onClick={()=>{setEntryOpen(false);resetEntry();}}>Cancel</button><button type="button" className="outline" disabled={busy} onClick={() => savePayment(false)}>Save draft</button><button className="primary" disabled={busy}>{busy ? "Posting..." : editingPayment ? "Save & post" : "Post transaction"}</button></div></form></Modal>}
      {transactionSection && <><div className="invoice-list-toolbar"><label className="invoice-list-search"><input type="search" aria-label={`Search ${pageTitle}`} placeholder={`Search ${pageTitle.toLowerCase()}…`} value={search} onChange={e=>setSearch(e.target.value)}/></label><small>{visiblePayments.length} entries</small></div>{visiblePayments.length === 0 && <p className="mini-empty">No matching transactions.</p>}<div className="bank-table"><div className="bank-row data-heading"><span>No.</span><span>Date</span><span>Type</span><span>Contact</span><span>Account</span><span>Reference</span><span>Amount</span><span>Status</span><span>Actions</span></div>{visiblePayments.map((p) => <div className="bank-row" key={p.id}><span className="code">PAY-{String(p.payment_number).padStart(6, "0")}</span><span>{p.payment_date}</span><span className="capitalize">{p.direction}</span><span>{p.contacts?.name ?? "—"}</span><span>{p.bank_accounts?.name ?? p.cash?.name ?? "—"}</span><span>{p.reference ?? "—"}</span><b>{pkr.format(Number(p.amount))}</b><span className={statusClass(p.status)}>{p.status}</span><span className="row-actions"><button title="View transaction" aria-label={`View transaction ${p.payment_number}`} onClick={()=>setViewingPayment(p)}><Eye size={14}/></button>{p.status === "draft" && <button title="Edit draft" aria-label={`Edit draft ${p.payment_number}`} onClick={()=>editPayment(p)}><Pencil size={14}/></button>}{p.status === "draft" && <button title="Post draft" onClick={() => postDraft(p.id)}><Plus size={14}/></button>}{["draft", "posted"].includes(p.status) && <button className="danger" title={p.status === "draft" ? "Delete draft" : "Reverse payment"} onClick={() => removeOrReverse(p)}>{p.status === "draft" ? <Trash2 size={14}/> : <RotateCcw size={14}/>}</button>}</span></div>)}</div></>}
      {section === "accounts" && <div className="sales-table"><div className="sales-row data-heading"><span>Name</span><span>Bank</span><span>Account number</span><span>IBAN</span><span>Ledger</span><span>Status</span><span/><span/></div>{banks.filter(b=>matchesRecord(b,toolsQuery)).map(b => <div className="sales-row" key={b.id}><b>{b.name}</b><span>{b.bank_name ?? "—"}</span><span>{b.account_number ?? "—"}</span><span>{b.iban ?? "—"}</span><span>{accounts.find(a => a.id === b.ledger_account_id)?.name ?? "—"}</span><span className={statusClass(b.active ? "Active" : "Inactive")}>{b.active ? "Active" : "Inactive"}</span><span className="row-actions"><RecordView companyId={companyId} table="bank_accounts" id={b.id} onSaved={load}/></span><span/></div>)}</div>}
    </article>}
    {viewingPayment&&<Modal onClose={()=>setViewingPayment(null)} title={`${viewingPayment.direction === "receipt" ? "Receipt" : "Payment"} PAY-${String(viewingPayment.payment_number).padStart(6,"0")}`} size="md" closeOnBackdrop><div className="detail-print"><dl className="details">{[["Date",viewingPayment.payment_date],["Status",viewingPayment.status],["Contact",viewingPayment.contacts?.name],["Branch",branches.find(b=>b.id===viewingPayment.branch_id)?.name],["Cash / Bank",viewingPayment.bank_accounts?.name||viewingPayment.cash?.name],["Amount",pkr.format(Number(viewingPayment.amount))],["Reference",viewingPayment.reference],["Notes",viewingPayment.notes],["Allocation",viewingPayment.sales_invoice_id ? `Sales invoice ${invoices.find(d=>d.id===viewingPayment.sales_invoice_id)?.number ?? viewingPayment.sales_invoice_id}` : viewingPayment.purchase_bill_id ? `Purchase bill ${bills.find(d=>d.id===viewingPayment.purchase_bill_id)?.number ?? viewingPayment.purchase_bill_id}` : "Unallocated / advance"]].map(([label,value])=><div key={label}><dt>{label}</dt><dd>{value||"—"}</dd></div>)}</dl></div></Modal>}
    {section === "reconciliation" && <article className="panel data-panel"><div className="panel-head"><div><h3>Bank reconciliation</h3><p>Import CSV, match posted entries and preserve an audit trail</p></div><span className="reconcile-progress"><CheckCircle2 size={15}/>{reconciledCount}/{statementLines.length} reconciled</span></div>
      <div className="reconcile-toolbar"><label>Bank account<select value={selectedBank} onChange={(e) => setSelectedBank(e.target.value)}><option value="">Select bank</option>{banks.filter((b) => b.active).map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}</select></label><label className="file-button"><Upload size={16}/> Import CSV<input type="file" accept=".csv,text/csv" disabled={!selectedBank || busy} onChange={(e) => { const file = e.target.files?.[0]; if (file) importStatement(file); e.currentTarget.value = ""; }}/></label><small>Columns: Date, Description, Reference, Debit, Credit</small></div>
      {!selectedBank ? <div className="mini-empty"><Landmark/><p>Select a bank account to reconcile.</p></div> : statementLines.length === 0 ? <div className="mini-empty"><Upload/><p>No statement lines. Import a bank CSV to begin.</p></div> : <div className="statement-table"><div className="statement-row data-heading"><span>Date</span><span>Description</span><span>Reference</span><span>Debit</span><span>Credit</span><span>Payment match</span><span>Status</span><span>Action</span></div>{statementLines.filter(line=>matchesRecord(line,toolsQuery)).map((line) => { const candidates = candidatesFor(line); return <div className="statement-row" key={line.id}><span>{line.transaction_date}</span><span>{line.description ?? "—"}</span><span>{line.reference ?? "—"}</span><b>{Number(line.debit) ? pkr.format(Number(line.debit)) : "—"}</b><b>{Number(line.credit) ? pkr.format(Number(line.credit)) : "—"}</b><span>{line.reconciled ? <span className="matched-payment"><Link2 size={13}/> PAY-{String(matchPayments.find((p) => p.id === line.matched_payment_id)?.payment_number ?? "").padStart(6, "0")}</span> : <select value={selectedMatches[line.id] ?? ""} onChange={(e) => setSelectedMatches({ ...selectedMatches, [line.id]: e.target.value })}><option value="">Select posted payment</option>{candidates.map((p) => <option key={p.id} value={p.id}>PAY-{String(p.payment_number).padStart(6, "0")} · {p.payment_date} · {pkr.format(Number(p.amount))}</option>)}</select>}</span><span className={line.reconciled ? "status" : "pending-status"}>{line.reconciled ? "Reconciled" : selectedMatches[line.id] ? "Suggested" : "Unmatched"}</span><span className="row-actions">{line.reconciled ? <button className="danger" title="Unreconcile" onClick={() => unreconcile(line.id)} disabled={busy}><Unlink size={14}/></button> : <button title="Reconcile" onClick={() => reconcile(line.id)} disabled={busy || !selectedMatches[line.id]}><CheckCircle2 size={14}/></button>}</span></div>; })}</div>}
    </article>}
  </div>;
}

