import { useEffect, useMemo, useState } from "react";
import { FilePlus2, Pencil, Plus, RotateCcw, Trash2, UserPlus, Search, X } from "lucide-react";
import { supabase } from "./lib/supabase";
import SalesQuotations from "./SalesQuotations";
import SalesHistory from "./SalesHistory";
import SalesOrders from "./SalesOrders";
import SalesCreditNotes from "./SalesCreditNotes";
type Branch = { id: string; name: string; active: boolean };
type Contact = {
  id: string;
  name: string;
  phone: string | null;
  email: string | null;
};
type Product = {
  id: string;
  sku: string;
  name: string;
  sale_price: number;
  gst_rate: number;
  active: boolean;
};
type Invoice = {
  id: string;
  invoice_number: number;
  invoice_date: string;
  reference: string | null;
  due_date: string;
  status: string;
  subtotal: number;
  gst_total: number;
  total: number;
  contacts: { name: string } | null;
};
type Line = {
  productId: string;
  sourceLineId: string;
  description: string;
  quantity: string;
  unitPrice: string;
  gstRate: string;
};
const blank = (): Line => ({
  productId: "",
  sourceLineId: "",
  description: "",
  quantity: "1",
  unitPrice: "",
  gstRate: "0",
});
const pkr = new Intl.NumberFormat("en-PK", {
  style: "currency",
  currency: "PKR",
});
export default function SalesView({
  companyId,
  branches,
  section = "invoices",
}: {
  companyId: string;
  branches: Branch[];
  section?: "invoices" | "quotations" | "orders" | "returns" | "history";
}) {
  const [contacts, setContacts] = useState<Contact[]>([]);
  const [products, setProducts] = useState<Product[]>([]);
  const [invoiceSearch, setInvoiceSearch] = useState("");
  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [customerOpen, setCustomerOpen] = useState(false);
  const [invoiceOpen, setInvoiceOpen] = useState(false);
  const [correctingPosted, setCorrectingPosted] = useState(false);
  const [editingInvoiceId, setEditingInvoiceId] = useState("");
  const [message, setMessage] = useState("");
  const [customer, setCustomer] = useState({
    name: "",
    phone: "",
    email: "",
    ntn: "",
    strn: "",
  });
  const [customerId, setCustomerId] = useState("");
  const [branchId, setBranchId] = useState("");
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10));
  const [dueDate, setDueDate] = useState(new Date().toISOString().slice(0, 10));
  const [reference, setReference] = useState("");
  const [lines, setLines] = useState<Line[]>([blank()]);
  const [busy, setBusy] = useState(false);
  const totals = useMemo(
    () =>
      lines.reduce(
        (a, l) => {
          const sub = Number(l.quantity || 0) * Number(l.unitPrice || 0);
          const gst = (sub * Number(l.gstRate || 0)) / 100;
          return {
            subtotal: a.subtotal + sub,
            gst: a.gst + gst,
            total: a.total + sub + gst,
          };
        },
        { subtotal: 0, gst: 0, total: 0 },
      ),
    [lines],
  );
  const filteredInvoices = useMemo(() => {
    const terms = invoiceSearch.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
    return invoices.filter(i => i.status !== "void").filter(i => {
      const values = [String(i.invoice_number), "INV-" + String(i.invoice_number).padStart(6,"0"), i.contacts?.name ?? "", i.reference ?? "", i.invoice_date, i.due_date, i.status, String(i.total), pkr.format(i.total), String(i.subtotal), String(i.gst_total)].join(" ").toLocaleLowerCase();
      return terms.every(term => values.includes(term));
    });
  }, [invoices, invoiceSearch]);
  async function loadInvoiceList() {
    const rows: Invoice[] = [];
    for (let offset = 0; ; offset += 500) {
      const result = await supabase.from("sales_invoices")
        .select("id,invoice_number,invoice_date,due_date,reference,status,subtotal,gst_total,total,contacts(name)")
        .eq("company_id", companyId).order("invoice_date", {ascending:false}).order("id")
        .range(offset, offset + 499);
      if (result.error) return {data:null,error:result.error};
      rows.push(...((result.data ?? []) as unknown as Invoice[]));
      if ((result.data?.length ?? 0) < 500) return {data:rows,error:null};
    }
  }
  async function load() {
    const [c, p, i] = await Promise.all([
      supabase
        .from("contacts")
        .select("id,name,phone,email")
        .eq("company_id", companyId)
        .in("kind", ["customer", "both"])
        .eq("active", true)
        .order("name"),
      supabase
        .from("products")
        .select("id,sku,name,sale_price,gst_rate,active")
        .eq("company_id", companyId)
        .eq("active", true)
        .order("name"),
      loadInvoiceList(),
    ]);
    if (c.error || p.error || i.error)
      setMessage(
        c.error?.message ||
          p.error?.message ||
          i.error?.message ||
          "Unable to load sales",
      );
    else {
      setContacts(c.data ?? []);
      setProducts(p.data ?? []);
      setInvoices((i.data ?? []) as unknown as Invoice[]);
      setBranchId(branches[0]?.id ?? "");
    }
  }
  useEffect(() => {
    load();
  }, [companyId]);
  async function addCustomer(e: React.FormEvent) {
    e.preventDefault();
    const { data, error } = await supabase
      .from("contacts")
      .insert({ company_id: companyId, kind: "customer", ...customer })
      .select("id")
      .single();
    if (error) setMessage(error.message);
    else {
      setMessage("Customer created successfully.");
      setCustomer({ name: "", phone: "", email: "", ntn: "", strn: "" });
      setCustomerOpen(false);
      await load();
      setCustomerId(data.id);
    }
  }
  function chooseProduct(index: number, id: string) {
    const product = products.find((p) => p.id === id);
    setLines((old) =>
      old.map((l, i) =>
        i === index
          ? {
              ...l,
              productId: id,
              sourceLineId: "",
              description: product?.name ?? "",
              unitPrice: String(product?.sale_price ?? ""),
              gstRate: String(product?.gst_rate ?? 0),
            }
          : l,
      ),
    );
  }
  function change(index: number, key: keyof Line, value: string) {
    setLines((old) =>
      old.map((l, i) => (i === index ? { ...l, [key]: value } : l)),
    );
  }
  const [addAnother, setAddAnother] = useState(false);
  const [dueMode, setDueMode] = useState("date");
  const [netDays, setNetDays] = useState("30");
  useEffect(() => {
    if (dueMode !== "net" || !date || !/^\d+$/.test(netDays)) return;
    const value = new Date(`${date}T00:00:00Z`);
    value.setUTCDate(value.getUTCDate() + Number(netDays));
    if (!Number.isNaN(value.getTime())) setDueDate(value.toISOString().slice(0, 10));
  }, [date, dueMode, netDays]);
  async function saveInvoice(shouldPost: boolean, addAnother = false) {
    setMessage("");
    if (!customerId || !branchId)
      return setMessage("Select a customer and branch.");
    if (lines.some((l) => !l.description || Number(l.quantity) <= 0))
      return setMessage("Every invoice line needs an item and quantity.");
    if (dueMode === "net" && (!/^\d+$/.test(netDays) || Number(netDays) > 3650)) return setMessage("Net terms must be between 0 and 3650 days.");
    setBusy(true);
    let invoiceId = editingInvoiceId;
    let createdNow = false;
    try {
      const { data: user } = await supabase.auth.getUser();
      if (!user.user) throw new Error("Session expired.");
      const payload = {
          company_id: companyId,
          branch_id: branchId,
          customer_id: customerId,
          invoice_date: date,
          due_date: dueDate,
          reference: reference || null,
          created_by: user.user.id,
        };
      if (correctingPosted) {
        const corrected = await supabase.rpc("save_sales_invoice_correction", {target_invoice:editingInvoiceId,header:payload,items:lines.map(l=>({sales_order_line_id:l.sourceLineId || null,product_id:l.productId || null,description:l.description,quantity:Number(l.quantity),unit_price:Number(l.unitPrice || 0),gst_rate:Number(l.gstRate || 0)})),should_post:shouldPost});
        if (corrected.error) throw corrected.error;
        setCorrectingPosted(false); setEditingInvoiceId(""); setInvoiceOpen(addAnother); setLines([blank()]); setReference("");
        setMessage("Invoice changes saved successfully."); await load(); return;
      }
      if (editingInvoiceId) {
        const updated = await supabase.from("sales_invoices").update(payload).eq("id", editingInvoiceId).eq("status", "draft");
        if (updated.error) throw updated.error;
        const removed = await supabase.from("sales_invoice_lines").delete().eq("invoice_id", editingInvoiceId); if (removed.error) throw removed.error;
      } else {
        const inv = await supabase.from("sales_invoices").insert(payload).select("id").single();
        if (inv.error) throw inv.error; invoiceId = inv.data.id; createdNow = true;
      }
      const inserted = await supabase
        .from("sales_invoice_lines")
        .insert(
          lines.map((l) => ({
            invoice_id: invoiceId,
            sales_order_line_id: l.sourceLineId || null,
            product_id: l.productId || null,
            description: l.description,
            quantity: Number(l.quantity),
            unit_price: Number(l.unitPrice || 0),
            gst_rate: Number(l.gstRate || 0),
          })),
        );
      if (inserted.error) throw inserted.error;
      if (shouldPost) { const posted = await supabase.rpc("post_sales_invoice", { target_invoice: invoiceId }); if (posted.error) throw posted.error; }
      setInvoiceOpen(addAnother);
      setLines([blank()]);
      setReference("");
      setEditingInvoiceId(""); setCorrectingPosted(false);
      setMessage(shouldPost ? "Sales invoice posted successfully." : "Invoice draft saved successfully.");
      await load();
    } catch (error) {
      if (createdNow && invoiceId)
        await supabase.from("sales_invoices").delete().eq("id", invoiceId);
      setMessage(
        error instanceof Error ? error.message : "Unable to post invoice.",
      );
    } finally {
      setBusy(false);
    }
  }
  async function editInvoice(id: string) {
    const [header, detail] = await Promise.all([supabase.from("sales_invoices").select("customer_id,branch_id,invoice_date,due_date,reference,status").eq("id",id).single(),supabase.from("sales_invoice_lines").select("sales_order_line_id,product_id,description,quantity,unit_price,gst_rate").eq("invoice_id",id).order("id")]);
    if (header.error || detail.error) return setMessage(header.error?.message || detail.error?.message || "Unable to load draft.");
    if (!["draft","posted"].includes(header.data.status)) return setMessage("Reverse allocated receipts before editing this invoice.");
    setCorrectingPosted(header.data.status === "posted");
    setDueMode("date"); setEditingInvoiceId(id); setCustomerId(header.data.customer_id); setBranchId(header.data.branch_id); setDate(header.data.invoice_date); setDueDate(header.data.due_date); setReference(header.data.reference || "");
    setLines((detail.data ?? []).map((l) => ({ productId:l.product_id || "",sourceLineId:l.sales_order_line_id || "",description:l.description,quantity:String(l.quantity),unitPrice:String(l.unit_price),gstRate:String(l.gst_rate) })));
    setInvoiceOpen(true); setMessage("");
  }
  async function correctInvoice(invoice: Invoice) {
    return editInvoice(invoice.id);
  }
  async function removeOrVoidInvoice(invoice: Invoice) {
    const action=invoice.status === "draft" ? "delete" : "void";
    if (!confirm(`${action === "delete" ? "Delete draft" : "Delete by reversing posted"} invoice INV-${String(invoice.invoice_number).padStart(6,"0")}?`)) return;
    const result=action === "delete" ? await supabase.from("sales_invoices").delete().eq("id",invoice.id).eq("status","draft") : await supabase.rpc("void_sales_invoice",{target_invoice:invoice.id,target_reason:"Voided by user"});
    if(result.error)setMessage(result.error.message);else{setMessage(action === "delete" ? "Invoice draft deleted successfully." : "Invoice voided with a reversing journal.");await load();}
  }
  return (
    <div className="accounting-stack">
      {section === "invoices" && <article className="panel data-panel">
        <div className="panel-head">
          <div>
            <h3>Sales invoices</h3>
            <p>Customers, GST invoices and receivables</p>
          </div>
          <div className="toolbar">
            <button
              className="outline"
              onClick={() => setCustomerOpen((v) => !v)}
            >
              {customerOpen ? <X size={16} /> : <UserPlus size={16} />} Customer
            </button>
            <button
              className="primary small-button"
              onClick={() => { setInvoiceOpen((v) => !v); setEditingInvoiceId(""); setCorrectingPosted(false); setLines([blank()]); }}
            >
              <FilePlus2 size={16} /> New invoice
            </button>
          </div>
        </div>
        {message && (
          <p className={message.includes("success") ? "notice" : "alert"}>
            {message}
          </p>
        )}
        {customerOpen && (
          <form className="customer-form" onSubmit={addCustomer}>
            <label>
              Name
              <input
                value={customer.name}
                onChange={(e) =>
                  setCustomer({ ...customer, name: e.target.value })
                }
                required
              />
            </label>
            <label>
              Phone
              <input
                value={customer.phone}
                onChange={(e) =>
                  setCustomer({ ...customer, phone: e.target.value })
                }
              />
            </label>
            <label>
              Email
              <input
                type="email"
                value={customer.email}
                onChange={(e) =>
                  setCustomer({ ...customer, email: e.target.value })
                }
              />
            </label>
            <label>
              NTN
              <input
                value={customer.ntn}
                onChange={(e) =>
                  setCustomer({ ...customer, ntn: e.target.value })
                }
              />
            </label>
            <label>
              STRN
              <input
                value={customer.strn}
                onChange={(e) =>
                  setCustomer({ ...customer, strn: e.target.value })
                }
              />
            </label>
            <button className="primary">Save customer</button>
          </form>
        )}
        {invoiceOpen && (
          <form className="invoice-form sales-entry-form" onSubmit={(e) => { e.preventDefault(); saveInvoice(true, addAnother); }}>
            <div className="invoice-meta">
              <label>
                Customer
                <select
                  value={customerId}
                  onChange={(e) => setCustomerId(e.target.value)}
                  required
                >
                  <option value="">Select customer</option>
                  {contacts.map((c) => (
                    <option value={c.id} key={c.id}>
                      {c.name}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                Branch
                <select
                  value={branchId}
                  onChange={(e) => setBranchId(e.target.value)}
                  required
                >
                  {branches
                    .filter((b) => b.active)
                    .map((b) => (
                      <option value={b.id} key={b.id}>
                        {b.name}
                      </option>
                    ))}
                </select>
              </label>
              <label>
                Invoice date
                <input
                  type="date"
                  value={date}
                  onChange={(e) => setDate(e.target.value)}
                  required
                />
              </label>
              <label>
                Due terms
                <select value={dueMode} onChange={(e) => setDueMode(e.target.value)}>
                  <option value="date">Specific date</option>
                  <option value="net">Net days</option>
                </select>
              </label>
              {dueMode === "net" && <label>Days after invoice date<input type="number" min="0" max="3650" step="1" value={netDays} onChange={(e) => setNetDays(e.target.value)} required /></label>}
              <label>
                Due date
                <input
                  type="date"
                  value={dueDate}
                  readOnly={dueMode === "net"}
                  onChange={(e) => setDueDate(e.target.value)}
                  required
                />
              </label>
              <label>
                Reference
                <input
                  value={reference}
                  onChange={(e) => setReference(e.target.value)}
                />
              </label>
            </div>
            <div className="invoice-lines">
              <div className="invoice-line data-heading">
                <span>Product/service</span>
                <span>Description</span>
                <span>Qty</span>
                <span>Price</span>
                <span>GST %</span>
                <span>Total</span>
                <span />
              </div>
              {lines.map((l, index) => {
                const lineTotal =
                  Number(l.quantity || 0) *
                  Number(l.unitPrice || 0) *
                  (1 + Number(l.gstRate || 0) / 100);
                return (
                  <div className="invoice-line" key={index}>
                    <select
                      value={l.productId}
                      onChange={(e) => chooseProduct(index, e.target.value)}
                    >
                      <option value="">Custom line</option>
                      {products.map((p) => (
                        <option value={p.id} key={p.id}>
                          {p.sku} — {p.name}
                        </option>
                      ))}
                    </select>
                    <input
                      value={l.description}
                      onChange={(e) =>
                        change(index, "description", e.target.value)
                      }
                      required
                    />
                    <input
                      type="number"
                      min="0.001"
                      step="0.001"
                      value={l.quantity}
                      onChange={(e) =>
                        change(index, "quantity", e.target.value)
                      }
                    />
                    <input
                      type="number"
                      min="0"
                      step="0.01"
                      value={l.unitPrice}
                      onChange={(e) =>
                        change(index, "unitPrice", e.target.value)
                      }
                    />
                    <input
                      type="number"
                      min="0"
                      max="100"
                      step="0.01"
                      value={l.gstRate}
                      onChange={(e) => change(index, "gstRate", e.target.value)}
                    />
                    <b>{pkr.format(lineTotal)}</b>
                    <button
                      type="button"
                      disabled={lines.length === 1}
                      onClick={() =>
                        setLines((old) => old.filter((_, i) => i !== index))
                      }
                    >
                      <Trash2 size={16} />
                    </button>
                  </div>
                );
              })}
            </div>
            <button
              type="button"
              className="text-button"
              onClick={() => setLines((old) => [...old, blank()])}
            >
              <Plus size={14} /> Add line
            </button>
            <div className="invoice-totals">
              <span>
                Subtotal <b>{pkr.format(totals.subtotal)}</b>
              </span>
              <span>
                GST <b>{pkr.format(totals.gst)}</b>
              </span>
              <span className="grand-total">
                Total <b>{pkr.format(totals.total)}</b>
              </span>
            </div>
            <div className="form-actions sales-entry-actions">
              <label className="entry-repeat"><input type="checkbox" checked={addAnother} onChange={e => setAddAnother(e.target.checked)} />Add another after saving</label>
              <button
                type="button"
                className="outline"
                onClick={() => setInvoiceOpen(false)}
              >
                Cancel
              </button>
              <button type="button" className="outline" disabled={busy || totals.total <= 0} onClick={() => saveInvoice(false, addAnother)}>Save draft</button>
              <button className="primary" disabled={busy || totals.total <= 0}>
                {busy ? "Saving..." : editingInvoiceId ? "Update & post" : "Post invoice"}
              </button>
            </div>
          </form>
        )}{" "}
        <div className="invoice-list-toolbar">
          <label className="invoice-list-search"><Search size={16}/><input type="search" aria-label="Search sales invoices" placeholder="Search invoices…" value={invoiceSearch} onChange={e => setInvoiceSearch(e.target.value)}/></label>
          <small role="status">{filteredInvoices.length} of {invoices.length} invoices</small>
        </div>
        {invoices.length > 0 && filteredInvoices.length === 0 && <div className="mini-empty"><Search/><p>No invoices match your search.</p><button className="outline" onClick={() => setInvoiceSearch("")}>Clear search</button></div>}
        {invoices.length === 0 ? (
          <div className="mini-empty">
            <FilePlus2 />
            <p>No sales invoices yet.</p>
          </div>
        ) : (
          <div className="sales-table">
            <div className="sales-row data-heading">
              <span>Invoice</span>
              <span>Date</span>
              <span>Customer</span>
              <span>Subtotal</span>
              <span>GST</span>
              <span>Total</span>
              <span>Status</span>
              <span>Actions</span>
            </div>
            {filteredInvoices.map((i) => (
              <div className="sales-row" key={i.id}>
                <span className="code">
                  INV-{String(i.invoice_number).padStart(6, "0")}
                </span>
                <span>{i.invoice_date}</span>
                <span>{i.contacts?.name ?? "—"}</span>
                <span>{pkr.format(i.subtotal)}</span>
                <span>{pkr.format(i.gst_total)}</span>
                <b>{pkr.format(i.total)}</b>
                <span className="status">{i.status}</span>
                <span className="row-actions">
                  {["draft","posted"].includes(i.status) && <button className="outline" disabled={busy} title="Edit invoice" onClick={() => void correctInvoice(i)}><Pencil size={14}/> Edit</button>}
                  {["draft","posted"].includes(i.status) && <button className="danger invoice-action" disabled={busy} title={i.status === "draft" ? "Delete draft" : "Delete by reversing posted invoice"} onClick={() => void removeOrVoidInvoice(i)}><Trash2 size={14}/> Delete</button>}
                  {i.status === "paid" && <small>Reverse receipt before editing</small>}
                  {i.status === "void" && <small>Reversed</small>}
                </span>
              </div>
            ))}
          </div>
        )}
      </article>}
      {section === "history" && <SalesHistory companyId={companyId}/>}
      {section === "returns" && <SalesCreditNotes companyId={companyId} onChanged={load}/>}
      {section === "quotations" && <SalesQuotations companyId={companyId} branches={branches} onConverted={load}/>}
      {section === "orders" && <SalesOrders companyId={companyId} branches={branches} customers={contacts} products={products} onConverted={load}/>}
    </div>
  );
}
