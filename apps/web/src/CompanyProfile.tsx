import { useState } from "react";
import { ImagePlus, Trash2 } from "lucide-react";
import { supabase } from "./lib/supabase";
import { fileToLogoDataUrl } from "./lib/logoImage";
import Modal from "./Modal";

export type CompanyProfile = {
  id: string; name: string; legal_name: string | null; ntn: string | null; strn: string | null; gst_registered: boolean;
  address?: string | null; phone?: string | null; email?: string | null; website?: string | null; logo_data_url?: string | null;
};

/** Edit the company letterhead that appears at the top of every exported PDF. */
export default function CompanyProfileModal({ company, onClose, onSaved }: { company: CompanyProfile; onClose: () => void; onSaved: () => void }) {
  const [form, setForm] = useState({
    name: company.name ?? "", legal_name: company.legal_name ?? "", ntn: company.ntn ?? "", strn: company.strn ?? "",
    address: company.address ?? "", phone: company.phone ?? "", email: company.email ?? "", website: company.website ?? "",
  });
  const [gst, setGst] = useState(!!company.gst_registered);
  const [logo, setLogo] = useState<string | null>(company.logo_data_url ?? null);
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);
  const set = (key: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => setForm({ ...form, [key]: e.target.value });

  async function pickLogo(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    e.target.value = "";
    if (!file) return;
    try { setLogo(await fileToLogoDataUrl(file)); setMessage(""); } catch (error) { setMessage(error instanceof Error ? error.message : "Unable to use this image."); }
  }
  async function save(e: React.FormEvent) {
    e.preventDefault();
    const clean = (v: string) => v.trim() || null;
    if (form.name.trim().length < 2) return setMessage("Company name is required.");
    if (form.email.trim() && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(form.email.trim())) return setMessage("Enter a valid email address.");
    if (form.address.length > 300) return setMessage("Address must be 300 characters or fewer.");
    setBusy(true); setMessage("");
    const r = await supabase.from("companies").update({
      name: form.name.trim(), legal_name: clean(form.legal_name), ntn: clean(form.ntn), strn: clean(form.strn), gst_registered: gst,
      address: clean(form.address), phone: clean(form.phone), email: clean(form.email), website: clean(form.website), logo_data_url: logo,
    }).eq("id", company.id).select("id").single();
    setBusy(false);
    if (r.error) {
      setMessage(/column|schema cache/i.test(r.error.message) ? "Letterhead fields are not available yet because the database update is still being applied. Try again in a few minutes." : r.error.message);
      return;
    }
    onSaved();
    onClose();
  }

  return <Modal onClose={onClose} title="Edit company details" size="lg" subtitle="These details appear in the letterhead of every PDF you export: invoices, bills, reports and payslips." message={message}>
    <form className="entry-grid" onSubmit={save}>
      <label>Company name<input required value={form.name} onChange={set("name")} /></label>
      <label>Legal name<input value={form.legal_name} onChange={set("legal_name")} placeholder="e.g. UltraNet Security (Pvt) Ltd" /></label>
      <label>NTN<input value={form.ntn} onChange={set("ntn")} /></label>
      <label>STRN<input value={form.strn} onChange={set("strn")} /></label>
      <label className="wide">Address<textarea rows={2} maxLength={300} value={form.address} onChange={set("address")} placeholder="Shop / street, area, city" /></label>
      <label>Phone<input value={form.phone} onChange={set("phone")} /></label>
      <label>Email<input type="email" value={form.email} onChange={set("email")} /></label>
      <label className="wide">Website<input value={form.website} onChange={set("website")} placeholder="www.example.com" /></label>
      <label className="checkbox wide"><input type="checkbox" checked={gst} onChange={(e) => setGst(e.target.checked)} /> Registered for GST</label>
      <div className="wide logo-field">
        <span className="logo-label">Company logo</span>
        <div className="logo-row">
          <div className="logo-preview">{logo ? <img src={logo} alt="Company logo preview" /> : <span>No logo</span>}</div>
          <div className="logo-actions">
            <label className="outline logo-upload"><ImagePlus size={16} /> {logo ? "Change logo" : "Upload logo"}<input type="file" accept="image/png,image/jpeg,image/webp" onChange={pickLogo} hidden /></label>
            {logo && <button type="button" className="outline danger-outline" onClick={() => setLogo(null)}><Trash2 size={15} /> Remove</button>}
            <small>PNG or JPG. It is resized automatically and appears at the top-left of your PDFs.</small>
          </div>
        </div>
      </div>
      <div className="form-actions wide"><button type="button" className="outline" onClick={onClose}>Cancel</button><button className="primary" disabled={busy}>{busy ? "Saving…" : "Save details"}</button></div>
    </form>
  </Modal>;
}
