import { useEffect, useState } from "react";
import { Check } from "lucide-react";
import { supabase } from "./lib/supabase";

type Counts = { customers: number; products: number; receipts: number };

/** A short checklist for a new company. Each step ticks itself when real data exists. */
export default function GettingStarted({ companyId, hasLetterhead, invoiceCount, onGo, onTour }: { companyId: string; hasLetterhead: boolean; invoiceCount: number; onGo: (key: string) => void; onTour: () => void }) {
  const storageKey = `cloudledger.gs.v1.${companyId}`;
  const [counts, setCounts] = useState<Counts | null>(null);
  const [dismissed, setDismissed] = useState(() => { try { return localStorage.getItem(storageKey) === "1"; } catch { return false; } });

  useEffect(() => {
    let live = true;
    const count = async (table: string, filter?: [string, string]) => {
      let query = supabase.from(table).select("id", { count: "exact", head: true }).eq("company_id", companyId);
      if (filter) query = query.eq(filter[0], filter[1]);
      const r = await query;
      return r.error ? 0 : (r.count ?? 0);
    };
    void Promise.all([count("contacts", ["kind", "customer"]), count("products"), count("payments", ["direction", "receipt"])]).then(([customers, products, receipts]) => { if (live) setCounts({ customers, products, receipts }); });
    return () => { live = false; };
  }, [companyId, invoiceCount]);

  if (dismissed || !counts) return null;
  const items = [
    { key: "settings-company", done: hasLetterhead, title: "Add your company details", text: "Address, phone, NTN and logo appear on every invoice and report PDF.", action: "Open settings" },
    { key: "customers", done: counts.customers > 0, title: "Add your first customer", text: "Customers and their tax details are used on every invoice.", action: "Add customer" },
    { key: "products", done: counts.products > 0, title: "Add products or services", text: "Set prices and GST once, then pick them on invoices.", action: "Add items" },
    { key: "invoices", done: invoiceCount > 0, title: "Create your first invoice", text: "Save it as a draft, or post it to record the sale.", action: "New invoice" },
    { key: "receipts", done: counts.receipts > 0, title: "Record a payment received", text: "Match a receipt to an invoice and watch receivables drop.", action: "Record receipt" },
  ];
  const done = items.filter((i) => i.done).length;
  if (done === items.length) return null;
  return <section className="getting-started" aria-label="Getting started">
    <header>
      <div><h3>Get started: {done} of {items.length} done</h3><p>Five steps to your first set of books. Each one ticks itself when you finish it.</p></div>
      <div><button className="outline small-button" onClick={onTour}>Take the tour</button> <button className="gs-dismiss" onClick={() => { try { localStorage.setItem(storageKey, "1"); } catch { /* shown again next visit */ } setDismissed(true); }}>Hide</button></div>
    </header>
    <div className="gs-bar" aria-hidden="true"><i style={{ width: `${(done / items.length) * 100}%` }} /></div>
    <div className="gs-list">
      {items.map((item) => <div key={item.key} className={`gs-item${item.done ? " done" : ""}`}>
        <span className="gs-check" aria-hidden="true">{item.done && <Check size={14} />}</span>
        <div><b>{item.title}</b><small>{item.text}</small>{!item.done && <button className="outline" onClick={() => onGo(item.key)}>{item.action}</button>}</div>
      </div>)}
    </div>
  </section>;
}
