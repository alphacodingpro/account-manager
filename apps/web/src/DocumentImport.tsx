import { useState } from "react";
import { FileSearch, Plus, Trash2, UploadCloud } from "lucide-react";
import { reviewedAmounts, type ExtractedBill } from "./lib/documentImport";
import "./DocumentImport.css";
import { reviewDocumentLines } from "./lib/documentReview";
import { scanSupplierDocument } from "./lib/localDocumentScan";

type Supplier = { id: string; name: string };
type Account = { id: string; code: string; name: string; type: string; active: boolean };
type ReviewedLine = { description: string; quantity: string; unitPrice: string; gstRate: string; accountId: string };
export type ReviewedDocument = { supplierId: string; date: string; reference: string; lines: { description: string; quantity: number; unitPrice: number; gstRate: number; accountId: string }[]; sourceName: string };

export default function DocumentImport({ companyId, suppliers, accounts, onApply, onCreateAccount }: {
  companyId: string; suppliers: Supplier[]; accounts: Account[]; onApply: (data: ReviewedDocument) => void;
  onCreateAccount: (code: string, name: string) => Promise<string>;
}) {
  const [source, setSource] = useState<ExtractedBill | null>(null);
  const [sourceName, setSourceName] = useState("");
  const [supplierId, setSupplierId] = useState("");
  const [date, setDate] = useState("");
  const [reference, setReference] = useState("");
  const [lines, setLines] = useState<ReviewedLine[]>([]);
  const [subtotal, setSubtotal] = useState("");
  const [gst, setGst] = useState("");
  const [total, setTotal] = useState("");
  const [code, setCode] = useState("");
  const [accountName, setAccountName] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const expenseAccounts = accounts.filter((account) => account.active && account.type === "expense");
  const review = reviewDocumentLines(lines, { subtotal, gst, total }, expenseAccounts.map((account) => account.id));
  const validation = review.error;
  const { subtotal: lineSubtotal, gst: lineGst, total: lineTotal } = review.totals;

  async function choose(file?: File) {
    if (!file) return;
    setBusy(true); setError(""); setSource(null);
    try {
      const extracted = await scanSupplierDocument(file, companyId);
      const text = extracted.text;
      if (text.trim().length < 25) throw new Error("No usable text was found. Try a clearer scan or enter the bill manually.");
      setSource(extracted); setSourceName(file.name);
      setSupplierId(suppliers.find((item) => item.name.trim().toLowerCase() === extracted.supplier.toLowerCase())?.id ?? "");
      setDate(extracted.invoiceDate); setReference(extracted.reference);
      setSubtotal(extracted.subtotal?.toFixed(2) ?? ""); setGst(extracted.gst?.toFixed(2) ?? ""); setTotal(extracted.total?.toFixed(2) ?? "");
      const rate = extracted.subtotal !== null && extracted.gst !== null && extracted.total !== null ? reviewedAmounts(extracted.subtotal, extracted.gst, extracted.total).rate : 0;
      setLines(extracted.items.map((item) => ({ description: item.description, quantity: String(item.quantity), unitPrice: item.unitPrice.toFixed(2), gstRate: String(rate), accountId: "" })));
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to read document."); }
    finally { setBusy(false); }
  }

  async function createAccount() {
    setBusy(true); setError("");
    try { const id = await onCreateAccount(code.trim(), accountName.trim()); setLines((old) => old.map((line) => ({ ...line, accountId: line.accountId || id }))); setCode(""); setAccountName(""); }
    catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to create expense account."); }
    finally { setBusy(false); }
  }

  function apply() {
    setError("");
    if (!supplierId || !date || !reference.trim()) return setError("Supplier, date and supplier invoice number are required.");
    if (validation) return setError(validation);
    onApply({ supplierId, date, reference: reference.trim(), lines: lines.map((line) => ({ description: line.description.trim(), quantity: Number(line.quantity), unitPrice: Number(line.unitPrice), gstRate: Number(line.gstRate), accountId: line.accountId })), sourceName });
  }

  return <section className="document-import">
    <div className="document-import-head"><FileSearch size={20}/><div><h4>Import and review a supplier document</h4><p>Local text extraction only. Every value requires your review; this creates an editable draft.</p></div></div>
    <label className="document-upload"><UploadCloud size={18}/>{busy ? "Reading document…" : "Choose PDF, image, DOCX or TXT"}<input type="file" accept=".pdf,.png,.jpg,.jpeg,.webp,.docx,.txt" disabled={busy} onChange={(event) => { void choose(event.target.files?.[0]); event.target.value = ""; }}/></label>
    {error && <p className="alert">{error}</p>}
    {source && <><p className="document-source">Source: <b>{sourceName}</b> · {source.engine || "Browser OCR / text extraction"}. Compare every value against the original document before applying.</p>
      {source.warnings.length > 0 && <ul className="document-warnings">{source.warnings.map((warning) => <li key={warning}>{warning}</li>)}</ul>}
      {source.tables?.map((table, index) => <div className="document-table-scroll" key={index}><table className="document-summary"><caption>Original scanned table {index + 1}</caption><tbody>{table.map((row, rowIndex) => <tr key={rowIndex}>{row.map((cell, cellIndex) => <td key={cellIndex}>{cell}</td>)}</tr>)}</tbody></table></div>)}
      <div className="document-table-scroll"><table className="document-summary"><caption>Scanned invoice — {source.items.length} detected items</caption><thead><tr><th>#</th><th>Item / serial details</th><th>Quantity</th><th>Unit price (PKR)</th><th>Amount (PKR)</th></tr></thead><tbody>
        {source.items.map((item, index) => <tr key={index}><td>{index + 1}</td><td>{item.description}</td><td>{item.quantity}</td><td>{item.unitPrice.toFixed(2)}</td><td>{item.amount.toFixed(2)}</td></tr>)}
        {!source.items.length && <tr><td colSpan={5}>No complete item rows detected. Compare the extracted text and add missing lines below.</td></tr>}
      </tbody><tfoot><tr><th colSpan={2}>Detected totals</th><td>{source.items.reduce((sum, item) => sum + item.quantity, 0)}</td><td/><td>{source.items.reduce((sum, item) => sum + item.amount, 0).toFixed(2)}</td></tr></tfoot></table></div>
      <div className="document-fields">
        <label>Supplier<select value={supplierId} onChange={(event) => setSupplierId(event.target.value)}><option value="">Select a registered supplier</option>{suppliers.map((supplier) => <option key={supplier.id} value={supplier.id}>{supplier.name}</option>)}</select></label>
        <label>Bill date<input type="date" value={date} onChange={(event) => setDate(event.target.value)}/></label>
        <label>Supplier invoice number<input value={reference} onChange={(event) => setReference(event.target.value)}/></label>
        <label>Subtotal (PKR)<input type="number" min="0" step="0.01" value={subtotal} onChange={(event) => setSubtotal(event.target.value)}/></label>
        <label>GST amount (PKR)<input type="number" min="0" step="0.01" value={gst} onChange={(event) => setGst(event.target.value)}/></label>
        <label>Invoice total (PKR)<input type="number" min="0" step="0.01" value={total} onChange={(event) => setTotal(event.target.value)}/></label>
      </div>
      <div className="document-items"><h4>Invoice item lines</h4><p className="document-source">Only clearly matched rows are suggested. Add missing rows and verify every item against the PDF.</p>
        {lines.map((line, index) => <div className="document-item" key={index}>
          <label>Description<textarea rows={2} aria-label={`Line ${index + 1} description`} value={line.description} onChange={(event) => setLines((old) => old.map((item, i) => i === index ? { ...item, description: event.target.value } : item))}/></label>
          <label>Qty<input aria-label={`Line ${index + 1} quantity`} type="number" step="0.001" min="0.001" value={line.quantity} onChange={(event) => setLines((old) => old.map((item, i) => i === index ? { ...item, quantity: event.target.value } : item))}/></label>
          <label>Unit price<input aria-label={`Line ${index + 1} unit price`} type="number" step="0.01" min="0" value={line.unitPrice} onChange={(event) => setLines((old) => old.map((item, i) => i === index ? { ...item, unitPrice: event.target.value } : item))}/></label>
          <label>GST %<input aria-label={`Line ${index + 1} GST rate`} type="number" step="0.01" min="0" max="100" value={line.gstRate} onChange={(event) => setLines((old) => old.map((item, i) => i === index ? { ...item, gstRate: event.target.value } : item))}/></label>
          <label>Expense account<select aria-label={`Line ${index + 1} expense account`} value={line.accountId} onChange={(event) => setLines((old) => old.map((item, i) => i === index ? { ...item, accountId: event.target.value } : item))}><option value="">Select account</option>{expenseAccounts.map((account) => <option key={account.id} value={account.id}>{account.code} · {account.name}</option>)}</select></label>
          <button type="button" title="Remove line" aria-label={`Remove line ${index + 1}`} onClick={() => setLines((old) => old.filter((_, i) => i !== index))}><Trash2 size={15}/></button>
        </div>)}
        <button type="button" className="outline" onClick={() => setLines((old) => [...old, { description: "", quantity: "1", unitPrice: "", gstRate: "0", accountId: "" }])}><Plus size={15}/> Add missing line</button>
        <p className="document-source">Lines: {lineSubtotal.toFixed(2)} + GST {lineGst.toFixed(2)} = {lineTotal.toFixed(2)} PKR</p>
        <p className="document-source" aria-live="polite">Difference from printed amounts (PKR): subtotal {review.differences.subtotal.toFixed(2)} · GST {review.differences.gst.toFixed(2)} · total {review.differences.total.toFixed(2)}</p>
      </div>
      <details className="document-account"><summary>Expense account missing? Create it after review</summary><div><input placeholder="Unique account code" value={code} onChange={(event) => setCode(event.target.value)}/><input placeholder="Account name" value={accountName} onChange={(event) => setAccountName(event.target.value)}/><button type="button" className="outline" disabled={busy || !code.trim() || !accountName.trim()} onClick={createAccount}>Create account</button></div></details>
      {validation && <p className="alert">{validation}</p>}
      <details className="document-text"><summary>Show extracted text for comparison</summary><pre>{source.text}</pre></details>
      <button type="button" className="primary" disabled={busy || Boolean(validation)} onClick={apply}>Use reviewed lines in bill draft</button>
      <p className="document-source">Stock products must be assigned manually in the draft. Keep this document open for comparison before posting.</p>
    </>}
  </section>;
}
