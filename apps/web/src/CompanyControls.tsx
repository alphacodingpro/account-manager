import { useState } from "react";
import { DatabaseBackup, Lock, LockOpen } from "lucide-react";
import { supabase } from "./lib/supabase";
import Modal, { msgClass } from "./Modal";
import { pdfDate } from "./lib/pdfExport";

/** Books lock date and full data backup, for owners and admins. */
export default function CompanyControls({ companyId, companyName, lockedThrough, onChanged }: { companyId: string; companyName: string; lockedThrough?: string | null; onChanged: () => void }) {
  const [open, setOpen] = useState(false);
  const [date, setDate] = useState(lockedThrough ?? "");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const today = new Date().toISOString().slice(0, 10);

  async function saveLock(value: string | null) {
    setBusy(true); setMessage("");
    const r = await supabase.rpc("set_books_lock", { target_company: companyId, lock_date: value });
    setBusy(false);
    if (r.error) { setMessage(/function|schema cache/i.test(r.error.message) ? "The books lock needs the latest database update, which is still being applied. Try again in a few minutes." : r.error.message); return; }
    setOpen(false); onChanged();
    setMessage(value ? `Books locked through ${pdfDate(value)}.` : "Books unlocked.");
  }
  async function backup() {
    setBusy(true); setMessage("");
    const r = await supabase.rpc("export_company_data", { target_company: companyId });
    setBusy(false);
    if (r.error) { setMessage(/function|schema cache/i.test(r.error.message) ? "Backup needs the latest database update, which is still being applied. Try again in a few minutes." : r.error.message); return; }
    const blob = new Blob([JSON.stringify(r.data, null, 1)], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = `${companyName.replace(/[^A-Za-z0-9]+/g, "-")}-backup-${today}.json`;
    document.body.appendChild(link); link.click(); link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 2000);
    setMessage("Backup downloaded. Keep it somewhere safe: it contains all of this company's records.");
  }

  return <>
    {message && !open && <p className={msgClass(message)} role="status">{message}</p>}
    <article className="panel control-grid">
      <div className="control-card">
        <div className="control-icon">{lockedThrough ? <Lock size={20} /> : <LockOpen size={20} />}</div>
        <div>
          <h3>Books lock date</h3>
          <p>{lockedThrough ? <>Books are locked through <b>{pdfDate(lockedThrough)}</b>. Nothing on or before that day can be posted, changed or voided.</> : "Not locked. Lock your books after you file taxes or close a period so past numbers cannot change by accident."}</p>
          <button className="outline small-button" onClick={() => { setDate(lockedThrough ?? ""); setMessage(""); setOpen(true); }}>{lockedThrough ? "Change lock date" : "Set lock date"}</button>
        </div>
      </div>
      <div className="control-card">
        <div className="control-icon"><DatabaseBackup size={20} /></div>
        <div>
          <h3>Full backup</h3>
          <p>Download every record of this company (accounts, contacts, invoices, bills, payments, journals, stock, payroll) as one file.</p>
          <button className="outline small-button" disabled={busy} onClick={() => void backup()}>{busy ? "Preparing…" : "Download backup (JSON)"}</button>
        </div>
      </div>
    </article>
    {open && <Modal onClose={() => setOpen(false)} title="Books lock date" size="sm" subtitle="Everything dated on or before this day becomes read-only." message={message}>
      <form className="entry-grid" onSubmit={(e) => { e.preventDefault(); void saveLock(date || null); }}>
        <label className="wide">Lock books through<input type="date" max={today} value={date} onChange={(e) => setDate(e.target.value)} /></label>
        <p className="muted wide">Posting, editing and voiding on or before this date will be refused. Only an owner or admin can change or remove the lock.</p>
        <div className="form-actions wide">
          {lockedThrough && <button type="button" className="outline danger-outline" disabled={busy} onClick={() => void saveLock(null)}>Remove lock</button>}
          <button type="button" className="outline" onClick={() => setOpen(false)}>Cancel</button>
          <button className="primary" disabled={busy || !date}>{busy ? "Saving…" : "Save lock date"}</button>
        </div>
      </form>
    </Modal>}
  </>;
}
