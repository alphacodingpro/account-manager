import { useEffect, useState } from "react";
import { Pencil, X } from "lucide-react";
import { supabase } from "./lib/supabase";
import "./PurchaseBillDetails.css";
import Modal, { statusClass } from "./Modal";

type Bill = {
  bill_number: number; supplier_reference: string | null; bill_date: string; due_date: string;
  status: string; notes: string | null; subtotal: number; gst_total: number; total: number;
  amount_paid: number; posted_at: string | null; contacts: { name: string } | null;
  branches: { name: string } | null; warehouses: { name: string } | null;
};
type Line = {
  id: string; description: string; quantity: number; unit_price: number; gst_rate: number;
  subtotal: number; gst_amount: number; total: number;
  products: { name: string } | null; accounts: { code: string; name: string } | null;
};
const money = new Intl.NumberFormat("en-PK", { style: "currency", currency: "PKR" });

export default function PurchaseBillDetails({ companyId, billId, onClose, onEdit }: {
  companyId: string; billId: string; onClose: () => void; onEdit: () => void;
}) {
  const [bill, setBill] = useState<Bill | null>(null);
  const [lines, setLines] = useState<Line[]>([]);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  useEffect(() => {
    let active = true;
    setBill(null); setLines([]); setError(""); setLoading(true);
    async function load() {
      // Verify the company on the parent before asking for its lines.
      const header = await supabase.from("purchase_bills")
        .select("bill_number,supplier_reference,bill_date,due_date,status,notes,subtotal,gst_total,total,amount_paid,posted_at,contacts(name),branches(name),warehouses(name)")
        .eq("company_id", companyId).eq("id", billId).single();
      if (!active) return;
      if (header.error) { setError(header.error.message); setLoading(false); return; }
      const detail = await supabase.from("purchase_bill_lines")
        .select("id,description,quantity,unit_price,gst_rate,subtotal,gst_amount,total,products(name),accounts(code,name)")
        .eq("bill_id", billId).order("id");
      if (!active) return;
      if (detail.error) setError(detail.error.message);
      else { setBill(header.data as unknown as Bill); setLines(detail.data as unknown as Line[]); }
      setLoading(false);
    }
    void load();
    return () => { active = false; };
  }, [companyId, billId]);
  const sums = lines.reduce((acc, line) => ({
    subtotal: acc.subtotal + Number(line.subtotal), gst: acc.gst + Number(line.gst_amount), total: acc.total + Number(line.total),
  }), { subtotal: 0, gst: 0, total: 0 });
  // Draft header amounts are populated only when the bill is posted.
  const subtotal = bill?.status === "draft" ? sums.subtotal : Number(bill?.subtotal ?? 0);
  const gst = bill?.status === "draft" ? sums.gst : Number(bill?.gst_total ?? 0);
  const total = bill?.status === "draft" ? sums.total : Number(bill?.total ?? 0);
  return <Modal onClose={onClose} title={bill ? `BILL-${String(bill.bill_number).padStart(6, "0")}` : "Bill details"} subtitle="Complete purchase bill and accounting review" size="xl" closeOnBackdrop><section className="purchase-detail" aria-label="Purchase bill details">
    
    {loading && <p role="status">Loading bill details…</p>}
    {error && <p className="alert" role="alert">{error}</p>}
    {bill && !error && <>
      <div className="purchase-detail-meta">
        <div><small>Supplier</small><strong>{bill.contacts?.name ?? "—"}</strong></div>
        <div><small>Status</small><strong><span className={statusClass(bill.status)}>{bill.status}</span></strong></div>
        <div><small>Supplier reference</small><strong>{bill.supplier_reference || "—"}</strong></div>
        <div><small>Bill date</small><strong>{bill.bill_date}</strong></div>
        <div><small>Due date</small><strong>{bill.due_date}</strong></div>
        <div><small>Branch / warehouse</small><strong>{bill.branches?.name ?? "—"} / {bill.warehouses?.name ?? "None"}</strong></div>
        {bill.posted_at && <div><small>Posted</small><strong>{new Date(bill.posted_at).toLocaleString("en-PK")}</strong></div>}
      </div>
      <div className="purchase-detail-scroll"><table><thead><tr><th>Description</th><th>Product / account</th><th>Qty</th><th>Unit price</th><th>GST %</th><th>Subtotal</th><th>GST</th><th>Total</th></tr></thead><tbody>
        {lines.map(line => <tr key={line.id}><td>{line.description}</td><td>{line.products?.name || (line.accounts ? `${line.accounts.code} · ${line.accounts.name}` : "—")}</td><td>{line.quantity}</td><td>{money.format(Number(line.unit_price))}</td><td>{line.gst_rate}%</td><td>{money.format(Number(line.subtotal))}</td><td>{money.format(Number(line.gst_amount))}</td><td>{money.format(Number(line.total))}</td></tr>)}
        {!lines.length && <tr><td colSpan={8}>No bill lines found.</td></tr>}
      </tbody></table></div>
      <div className="purchase-detail-totals"><span>Subtotal <b>{money.format(subtotal)}</b></span><span>Input GST <b>{money.format(gst)}</b></span><span className="grand-total">Total <b>{money.format(total)}</b></span><span>Paid <b>{money.format(Number(bill.amount_paid))}</b></span><span>Outstanding <b>{money.format(total - Number(bill.amount_paid))}</b></span></div>
      {bill.notes && <div className="purchase-detail-notes"><small>Notes</small><p>{bill.notes}</p></div>}
      {bill.notes?.startsWith("Imported from ") && <p className="purchase-detail-hint">Original uploaded file is not stored yet. Compare this draft with your own copy before posting.</p>}
      {bill.status === "draft" && <div className="form-actions"><button type="button" className="primary small-button" onClick={onEdit}><Pencil size={15}/> Edit draft</button></div>}
    </>}
  </section></Modal>;
}
