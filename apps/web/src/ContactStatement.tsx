import { useEffect, useState } from "react";
import { supabase } from "./lib/supabase";
import Modal, { msgClass } from "./Modal";
import PdfButton from "./PdfButton";
import { pdfDate, pdfMoney, type PdfSpec } from "./lib/pdfExport";

type Contact = { id: string; name: string; kind: string; phone?: string | null; email?: string | null; address?: string | null; ntn?: string | null; strn?: string | null };
type Line = { line_no: number; txn_date: string; doc_type: string; doc_number: string; reference: string | null; charges: number | string; payments: number | string; balance: number | string };

const iso = (d: Date) => d.toISOString().slice(0, 10);
/** Pakistan financial year: 1 July to 30 June. */
function financialYearStart() { const t = new Date(); return iso(new Date(Date.UTC(t.getMonth() >= 6 ? t.getFullYear() : t.getFullYear() - 1, 6, 1))); }

/** Statement of account for one customer or supplier: opening balance, documents and a running balance. */
export default function ContactStatement({ companyId, contact, onClose }: { companyId: string; contact: Contact; onClose: () => void }) {
  const supplier = contact.kind === "supplier";
  const [from, setFrom] = useState(financialYearStart());
  const [to, setTo] = useState(iso(new Date()));
  const [lines, setLines] = useState<Line[]>([]);
  const [message, setMessage] = useState("");
  const [loading, setLoading] = useState(false);

  async function load() {
    setLoading(true); setMessage("");
    const r = await supabase.rpc("get_contact_statement", { target_company: companyId, target_contact: contact.id, date_from: from, date_to: to });
    setLoading(false);
    if (r.error) { setLines([]); setMessage(/function|schema cache/i.test(r.error.message) ? "Statements need the latest database update, which is still being applied. Try again in a few minutes." : r.error.message); }
    else setLines((r.data ?? []) as Line[]);
  }
  useEffect(() => { void load(); }, []);

  const closing = lines.length ? Number(lines[lines.length - 1].balance) : 0;
  const money = (v: number | string) => Number(v) === 0 ? "—" : pdfMoney(v);
  function buildPdf(): PdfSpec {
    return {
      title: "Statement of Account", subtitle: `${pdfDate(from)} to ${pdfDate(to)}`, date: to,
      parties: [{ label: supplier ? "Supplier" : "Customer", lines: [contact.name, contact.address, [contact.phone && `Tel: ${contact.phone}`, contact.email].filter(Boolean).join("   "), [contact.ntn && `NTN: ${contact.ntn}`, contact.strn && `STRN: ${contact.strn}`].filter(Boolean).join("   ")] }],
      meta: [["Period from", pdfDate(from)], ["Period to", pdfDate(to)]],
      columns: [{ header: "Date", width: 24 }, { header: "Type", width: 24 }, { header: "Number", width: 28 }, { header: "Reference" }, { header: supplier ? "Billed" : "Charged", align: "right", width: 28 }, { header: supplier ? "Paid / credited" : "Received / credited", align: "right", width: 30 }, { header: "Balance", align: "right", width: 30 }],
      rows: lines.map((l) => [pdfDate(l.txn_date), l.doc_type, l.doc_number, l.reference ?? "", Number(l.charges) ? pdfMoney(l.charges) : "", Number(l.payments) ? pdfMoney(l.payments) : "", pdfMoney(l.balance)]),
      totals: [[supplier ? "Amount payable" : "Amount due", pdfMoney(closing), "grand"]],
      notes: supplier ? "Balance is what you owe this supplier at the end of the period." : "Please pay the amount due. If you have already paid, kindly ignore this statement and send us the payment details.",
      filename: `Statement-${contact.name.replace(/\s+/g, "-")}-${to}`,
    };
  }

  return <Modal onClose={onClose} title={`Statement: ${contact.name}`} size="xl" subtitle={supplier ? "What you billed from and paid to this supplier." : "What you invoiced and received from this customer."} message={message} closeOnBackdrop>
    <form className="statement-filters" onSubmit={(e) => { e.preventDefault(); void load(); }}>
      <label>From<input type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} /></label>
      <label>To<input type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)} /></label>
      <button className="primary" disabled={loading}>{loading ? "Loading…" : "Show"}</button>
      <PdfButton label="Download PDF" className="outline" build={buildPdf} disabled={!lines.length || loading} />
    </form>
    {message && <p className={msgClass(message)}>{message}</p>}
    <div className="account-table">
      <table className="contacts-table">
        <thead><tr><th>Date</th><th>Type</th><th>Number</th><th>Reference</th><th className="num">{supplier ? "Billed" : "Charged"}</th><th className="num">{supplier ? "Paid / credited" : "Received / credited"}</th><th className="num">Balance</th></tr></thead>
        <tbody>
          {lines.map((l) => <tr key={`${l.line_no}-${l.doc_number}`} className={l.line_no === 0 ? "statement-opening" : ""}><td>{pdfDate(l.txn_date)}</td><td>{l.doc_type}</td><td>{l.doc_number}</td><td>{l.reference ?? ""}</td><td className="num">{l.line_no === 0 ? "" : money(l.charges)}</td><td className="num">{l.line_no === 0 ? "" : money(l.payments)}</td><td className="num"><b>{pdfMoney(l.balance)}</b></td></tr>)}
          {!lines.length && !loading && <tr><td colSpan={7} className="mini-empty">No activity in this period.</td></tr>}
        </tbody>
      </table>
    </div>
    <p className="statement-total">{supplier ? "Amount payable" : "Amount due"}: <b>{pdfMoney(closing)}</b></p>
  </Modal>;
}
