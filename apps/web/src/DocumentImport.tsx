import { useState } from "react";
import { FileSearch, UploadCloud } from "lucide-react";
import { extractBillFields, readDocument, reviewedAmounts, type ExtractedBill } from "./lib/documentImport";
import "./DocumentImport.css";

type Supplier = { id: string; name: string };
type Account = { id: string; code: string; name: string; type: string; active: boolean };
export type ReviewedDocument = { supplierId: string; date: string; reference: string; description: string; accountId: string; subtotal: number; gstRate: number; sourceName: string };

export default function DocumentImport({ suppliers, accounts, onApply, onCreateAccount }: {
  suppliers: Supplier[]; accounts: Account[]; onApply: (data: ReviewedDocument) => void;
  onCreateAccount: (code: string, name: string) => Promise<string>;
}) {
  const [source, setSource] = useState<ExtractedBill | null>(null);
  const [sourceName, setSourceName] = useState("");
  const [supplierId, setSupplierId] = useState("");
  const [date, setDate] = useState("");
  const [reference, setReference] = useState("");
  const [description, setDescription] = useState("");
  const [accountId, setAccountId] = useState("");
  const [subtotal, setSubtotal] = useState("");
  const [gst, setGst] = useState("");
  const [total, setTotal] = useState("");
  const [code, setCode] = useState("");
  const [accountName, setAccountName] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const validation = reviewedAmounts(Number(subtotal), Number(gst), Number(total));
  const expenseAccounts = accounts.filter((account) => account.active && account.type === "expense");

  async function choose(file?: File) {
    if (!file) return;
    setBusy(true); setError(""); setSource(null);
    try {
      const text = await readDocument(file);
      if (text.trim().length < 25) throw new Error("No usable text was found. Try a clearer scan or enter the bill manually.");
      const extracted = extractBillFields(text);
      setSource(extracted); setSourceName(file.name);
      setSupplierId(suppliers.find((item) => item.name.trim().toLowerCase() === extracted.supplier.toLowerCase())?.id ?? "");
      setDate(extracted.invoiceDate); setReference(extracted.reference); setDescription("Document expense");
      setAccountId(""); setSubtotal(extracted.subtotal?.toFixed(2) ?? ""); setGst(extracted.gst?.toFixed(2) ?? ""); setTotal(extracted.total?.toFixed(2) ?? "");
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to read document."); }
    finally { setBusy(false); }
  }

  async function createAccount() {
    setBusy(true); setError("");
    try { const id = await onCreateAccount(code.trim(), accountName.trim()); setAccountId(id); setCode(""); setAccountName(""); }
    catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to create expense account."); }
    finally { setBusy(false); }
  }

  function apply() {
    setError("");
    if (!supplierId || !date || !reference.trim() || !description.trim() || !accountId) return setError("Supplier, date, reference, description and expense account are required.");
    if (validation.error) return setError(validation.error);
    onApply({ supplierId, date, reference: reference.trim(), description: description.trim(), accountId, subtotal: Number(subtotal), gstRate: validation.rate, sourceName });
  }

  return <section className="document-import">
    <div className="document-import-head"><FileSearch size={20}/><div><h4>Import and review a supplier document</h4><p>Local text extraction only. Every value requires your review; this creates an editable draft.</p></div></div>
    <label className="document-upload"><UploadCloud size={18}/>{busy ? "Reading document…" : "Choose PDF, image, DOCX or TXT"}<input type="file" accept=".pdf,.png,.jpg,.jpeg,.webp,.docx,.txt" disabled={busy} onChange={(event) => { void choose(event.target.files?.[0]); event.target.value = ""; }}/></label>
    {error && <p className="alert">{error}</p>}
    {source && <><p className="document-source">Source: <b>{sourceName}</b>. Compare every value against the original document before applying.</p>
      {source.warnings.length > 0 && <ul className="document-warnings">{source.warnings.map((warning) => <li key={warning}>{warning}</li>)}</ul>}
      <div className="document-fields">
        <label>Supplier<select value={supplierId} onChange={(event) => setSupplierId(event.target.value)}><option value="">Select a registered supplier</option>{suppliers.map((supplier) => <option key={supplier.id} value={supplier.id}>{supplier.name}</option>)}</select></label>
        <label>Bill date<input type="date" value={date} onChange={(event) => setDate(event.target.value)}/></label>
        <label>Supplier invoice number<input value={reference} onChange={(event) => setReference(event.target.value)}/></label>
        <label>Expense description<input value={description} onChange={(event) => setDescription(event.target.value)}/></label>
        <label>Subtotal (PKR)<input type="number" min="0" step="0.01" value={subtotal} onChange={(event) => setSubtotal(event.target.value)}/></label>
        <label>GST amount (PKR)<input type="number" min="0" step="0.01" value={gst} onChange={(event) => setGst(event.target.value)}/></label>
        <label>Invoice total (PKR)<input type="number" min="0" step="0.01" value={total} onChange={(event) => setTotal(event.target.value)}/></label>
        <label>Expense account<select value={accountId} onChange={(event) => setAccountId(event.target.value)}><option value="">Select the right account</option>{expenseAccounts.map((account) => <option key={account.id} value={account.id}>{account.code} · {account.name}</option>)}</select></label>
      </div>
      <details className="document-account"><summary>Expense account missing? Create it after review</summary><div><input placeholder="Unique account code" value={code} onChange={(event) => setCode(event.target.value)}/><input placeholder="Account name" value={accountName} onChange={(event) => setAccountName(event.target.value)}/><button type="button" className="outline" disabled={busy || !code.trim() || !accountName.trim()} onClick={createAccount}>Create account</button></div></details>
      {validation.error && <p className="alert">{validation.error}</p>}
      <details className="document-text"><summary>Show extracted text for comparison</summary><pre>{source.text}</pre></details>
      <button type="button" className="primary" disabled={busy || Boolean(validation.error)} onClick={apply}>Use reviewed values in bill draft</button>
      <p className="document-source">Multiple stock items or special tax rules need line-by-line corrections in the draft before posting.</p>
    </>}
  </section>;
}
