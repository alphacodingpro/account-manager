import { useEffect, useMemo, useState } from "react";
import { Eye, FilePlus2, FileSearch, Pencil, Plus, RotateCcw, Trash2, UserPlus, X } from "lucide-react";
import { supabase } from "./lib/supabase";
import DocumentImport, { type ReviewedDocument } from "./DocumentImport";
import PurchaseBillDetails from "./PurchaseBillDetails";
import PurchaseDebitNotes from "./PurchaseDebitNotes";
import PurchaseOrders from "./PurchaseOrders";

type Branch = { id: string; name: string; active: boolean };
type Account = { id: string; code: string; name: string; type: string; active: boolean };
type Supplier = { id: string; name: string };
type Product = { id: string; name: string; purchase_price: number; gst_rate: number; is_service: boolean };
type Warehouse = { id: string; branch_id: string; name: string };
type Bill = { id: string; bill_number: number; bill_date: string; due_date: string; status: string; total: number; amount_paid: number; contacts: { name: string } | null };
type Line = { productId: string; accountId: string; sourceLineId: string; description: string; quantity: string; unitPrice: string; gstRate: string };
const blank = (): Line => ({ productId: "", accountId: "", sourceLineId: "", description: "", quantity: "1", unitPrice: "", gstRate: "0" });
const pkr = new Intl.NumberFormat("en-PK", { style: "currency", currency: "PKR" });

export default function PurchasesView({ companyId, branches, accounts, onAccountsChanged, section = "bills" }: { companyId: string; branches: Branch[]; accounts: Account[]; onAccountsChanged: () => Promise<void>; section?: "bills" | "orders" | "returns" }) {
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [products, setProducts] = useState<Product[]>([]);
  const [warehouses, setWarehouses] = useState<Warehouse[]>([]);
  const [bills, setBills] = useState<Bill[]>([]);
  const [supplierOpen, setSupplierOpen] = useState(false);
  const [billOpen, setBillOpen] = useState(false);
  const [importOpen, setImportOpen] = useState(false);
  const [importedDraft, setImportedDraft] = useState(false);
  const [importSource, setImportSource] = useState("");
  const [draftNotes, setDraftNotes] = useState<string | null>(null);
  const [editingBillId, setEditingBillId] = useState("");
  const [viewingBillId, setViewingBillId] = useState("");
  const [supplierName, setSupplierName] = useState("");
  const [supplierId, setSupplierId] = useState("");
  const [branchId, setBranchId] = useState("");
  const [warehouseId, setWarehouseId] = useState("");
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10));
  const [dueDate, setDueDate] = useState(new Date().toISOString().slice(0, 10));
  const [reference, setReference] = useState("");
  const [lines, setLines] = useState<Line[]>([blank()]);
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);
  const expenseAccounts = accounts.filter((a) => a.active && a.type === "expense");
  const totals = useMemo(() => lines.reduce((a, l) => {
    const sub = Number(l.quantity || 0) * Number(l.unitPrice || 0);
    const gst = sub * Number(l.gstRate || 0) / 100;
    return { sub: a.sub + sub, gst: a.gst + gst, total: a.total + sub + gst };
  }, { sub: 0, gst: 0, total: 0 }), [lines]);

  async function load() {
    const [s, p, w, b] = await Promise.all([
      supabase.from("contacts").select("id,name").eq("company_id", companyId).in("kind", ["supplier", "both"]).eq("active", true).order("name"),
      supabase.from("products").select("id,name,purchase_price,gst_rate,is_service").eq("company_id", companyId).eq("active", true).order("name"),
      supabase.from("warehouses").select("id,branch_id,name").eq("company_id", companyId).eq("active", true).order("name"),
      supabase.from("purchase_bills").select("id,bill_number,bill_date,due_date,status,total,amount_paid,contacts(name)").eq("company_id", companyId).order("bill_date", { ascending: false }).limit(30),
    ]);
    const error = s.error || p.error || w.error || b.error;
    if (error) setMessage(error.message);
    else {
      setSuppliers(s.data ?? []); setProducts((p.data ?? []) as Product[]); setWarehouses(w.data ?? []); setBills((b.data ?? []) as unknown as Bill[]);
      const nextBranch = branchId || branches[0]?.id || ""; setBranchId(nextBranch);
      setWarehouseId((w.data ?? []).find((x) => x.branch_id === nextBranch)?.id ?? "");
    }
  }
  useEffect(() => { load(); }, [companyId]);
  useEffect(() => { setViewingBillId(""); }, [companyId]);
  function chooseProduct(index: number, id: string) {
    const p = products.find((x) => x.id === id);
    setLines((old) => old.map((l, i) => i === index ? { ...l, productId: id, sourceLineId: "", description: p?.name ?? "", unitPrice: String(p?.purchase_price ?? ""), gstRate: String(p?.gst_rate ?? 0), accountId: p?.is_service ? (expenseAccounts[0]?.id ?? "") : "" } : l));
  }
  function change(index: number, key: keyof Line, value: string) { setLines((old) => old.map((l, i) => i === index ? { ...l, [key]: value } : l)); }
  async function addSupplier(e: React.FormEvent) {
    e.preventDefault(); const result = await supabase.from("contacts").insert({ company_id: companyId, kind: "supplier", name: supplierName.trim() }).select("id").single();
    if (result.error) setMessage(result.error.message); else { setSupplierName(""); setSupplierOpen(false); setSupplierId(result.data.id); setMessage("Supplier created successfully."); await load(); }
  }
  async function createExpenseAccount(code: string, name: string): Promise<string> {
    if (!/^[A-Za-z0-9._-]{2,20}$/.test(code) || name.length < 2) throw new Error("Enter a unique 2–20 character code and account name.");
    const result = await supabase.from("accounts").insert({ company_id: companyId, code, name, type: "expense" }).select("id").single();
    if (result.error) throw result.error;
    await onAccountsChanged();
    return result.data.id;
  }
  function applyImportedDocument(reviewed: ReviewedDocument) {
    setSupplierId(reviewed.supplierId); setDate(reviewed.date); setDueDate(reviewed.date); setReference(reviewed.reference);
    setLines(reviewed.lines.map((line) => ({ productId: "", accountId: line.accountId, sourceLineId: "", description: line.description, quantity: String(line.quantity), unitPrice: line.unitPrice.toFixed(2), gstRate: String(line.gstRate) })));
    setEditingBillId(""); setImportedDraft(true); setImportSource(reviewed.sourceName); setDraftNotes(null); setBillOpen(true); setImportOpen(false);
    setMessage(`Values reviewed from ${reviewed.sourceName}. Check due date and bill lines, then save a draft.`);
  }
  async function saveBill(shouldPost: boolean) {
    setMessage("");
    if (shouldPost && importedDraft) return setMessage("First save the imported bill as a draft. Open it again after checking the document to post it.");
    if (!supplierId || !branchId) return setMessage("Select a supplier and branch.");
    if (lines.some((l) => !l.description || Number(l.quantity) <= 0 || (!l.productId && !l.accountId))) return setMessage("Complete every bill line.");
    setBusy(true); let billId = editingBillId; let createdNow = false;
    try {
      const { data: auth } = await supabase.auth.getUser(); if (!auth.user) throw new Error("Session expired.");
      if (reference.trim()) {
        const duplicates = await supabase.from("purchase_bills").select("id").eq("company_id", companyId).eq("supplier_id", supplierId).eq("supplier_reference", reference.trim()).neq("status", "void").limit(2);
        if (duplicates.error) throw duplicates.error;
        if (duplicates.data?.some((bill) => bill.id !== editingBillId)) throw new Error("This supplier invoice number already exists. Review the document to avoid a duplicate bill.");
      }
      const payload={ company_id: companyId, branch_id: branchId, warehouse_id: warehouseId || null, supplier_id: supplierId, supplier_reference: reference.trim() || null, bill_date: date, due_date: dueDate, notes: importedDraft ? `Imported from ${importSource}; reviewed and saved as draft.` : draftNotes, created_by: auth.user.id };
      if(editingBillId){const updated=await supabase.from("purchase_bills").update(payload).eq("id",editingBillId).eq("status","draft");if(updated.error)throw updated.error;const removed=await supabase.from("purchase_bill_lines").delete().eq("bill_id",editingBillId);if(removed.error)throw removed.error;}
      else{const created = await supabase.from("purchase_bills").insert(payload).select("id").single();if (created.error) throw created.error; billId = created.data.id; createdNow=true;}
      const inserted = await supabase.from("purchase_bill_lines").insert(lines.map((l) => ({ bill_id: billId, purchase_order_line_id: l.sourceLineId || null, product_id: l.productId || null, expense_account_id: l.accountId || null, description: l.description, quantity: Number(l.quantity), unit_price: Number(l.unitPrice || 0), gst_rate: Number(l.gstRate || 0) })));
      if (inserted.error) throw inserted.error;
      if(shouldPost){const posted = await supabase.rpc("post_purchase_bill", { target_bill: billId }); if (posted.error) throw posted.error;}
      setBillOpen(false); setLines([blank()]); setReference(""); setEditingBillId(""); setImportedDraft(false); setImportSource(""); setDraftNotes(null); setMessage(shouldPost ? "Purchase bill posted successfully." : "Bill draft saved successfully."); await load();
    } catch (error) { if (createdNow && billId) await supabase.from("purchase_bills").delete().eq("id", billId); setMessage(error instanceof Error ? error.message : "Unable to save bill."); }
    finally { setBusy(false); }
  }
  async function editBill(id:string){const [h,d]=await Promise.all([supabase.from("purchase_bills").select("supplier_id,branch_id,warehouse_id,bill_date,due_date,supplier_reference,status,notes").eq("id",id).single(),supabase.from("purchase_bill_lines").select("purchase_order_line_id,product_id,expense_account_id,description,quantity,unit_price,gst_rate").eq("bill_id",id).order("id")]);if(h.error||d.error)return setMessage(h.error?.message||d.error?.message||"Unable to load draft.");if(h.data.status!=="draft")return setMessage("Only draft bills can be edited.");setEditingBillId(id);setImportedDraft(false);setImportSource("");setDraftNotes(h.data.notes);setSupplierId(h.data.supplier_id);setBranchId(h.data.branch_id);setWarehouseId(h.data.warehouse_id||"");setDate(h.data.bill_date);setDueDate(h.data.due_date);setReference(h.data.supplier_reference||"");setLines((d.data??[]).map(l=>({productId:l.product_id||"",accountId:l.expense_account_id||"",sourceLineId:l.purchase_order_line_id||"",description:l.description,quantity:String(l.quantity),unitPrice:String(l.unit_price),gstRate:String(l.gst_rate)})));setBillOpen(true);setMessage("");}
  async function removeOrVoidBill(bill:Bill){const action=bill.status==="draft"?"delete":"void";if(!confirm(`${action==="delete"?"Delete draft":"Void posted"} bill BILL-${String(bill.bill_number).padStart(6,"0")}?`))return;const result=action==="delete"?await supabase.from("purchase_bills").delete().eq("id",bill.id).eq("status","draft"):await supabase.rpc("void_purchase_bill",{target_bill:bill.id,target_reason:"Voided by user"});if(result.error)setMessage(result.error.message);else{setMessage(action==="delete"?"Bill draft deleted successfully.":"Bill voided with a reversing journal.");await load();}}
  return <div className="accounting-stack">{section === "bills" && <article className="panel data-panel">
    <div className="panel-head"><div><h3>Purchase bills</h3><p>Suppliers, input GST, stock and payables</p></div><div className="toolbar">
      <button className="outline" onClick={() => setSupplierOpen((v) => !v)}>{supplierOpen ? <X size={16}/> : <UserPlus size={16}/>} Supplier</button>
      <button className="outline" onClick={() => setImportOpen((value) => !value)}><FileSearch size={16}/> Import document</button>
      <button className="primary small-button" onClick={() => {setBillOpen((v) => !v);setEditingBillId("");setImportedDraft(false);setImportSource("");setDraftNotes(null);setLines([blank()]);}}><FilePlus2 size={16}/> New bill</button>
    </div></div>
    {message && <p className={message.includes("success") ? "notice" : "alert"}>{message}</p>}
    {supplierOpen && <form className="customer-form" onSubmit={addSupplier}><label>Supplier name<input value={supplierName} onChange={(e) => setSupplierName(e.target.value)} required/></label><button className="primary">Save supplier</button></form>}
    {importOpen && <DocumentImport companyId={companyId} key={companyId} suppliers={suppliers} accounts={accounts} onApply={applyImportedDocument} onCreateAccount={createExpenseAccount}/>}
    {billOpen && <form className="invoice-form" onSubmit={(e)=>{e.preventDefault();saveBill(true);}}>
      <div className="invoice-meta"><label>Supplier<select value={supplierId} onChange={(e) => setSupplierId(e.target.value)} required><option value="">Select</option>{suppliers.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
      <label>Branch<select value={branchId} onChange={(e) => { setBranchId(e.target.value); setWarehouseId(warehouses.find((w) => w.branch_id === e.target.value)?.id ?? ""); }} required><option value="">Select</option>{branches.filter((b) => b.active).map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}</select></label>
      <label>Warehouse<select value={warehouseId} onChange={(e) => setWarehouseId(e.target.value)}><option value="">None</option>{warehouses.filter((w) => w.branch_id === branchId).map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}</select></label>
      <label>Bill date<input type="date" value={date} onChange={(e) => setDate(e.target.value)} required/></label><label>Due date<input type="date" value={dueDate} onChange={(e) => setDueDate(e.target.value)} required/></label></div>
      <label>Supplier reference<input value={reference} onChange={(e) => setReference(e.target.value)} placeholder="Optional"/></label>
      <div className="invoice-lines"><div className="purchase-line data-heading"><span>Product</span><span>Description</span><span>Expense account</span><span>Qty</span><span>Price</span><span>GST %</span><span>Total</span><span/></div>
      {lines.map((l, i) => <div className="purchase-line" key={i}><select value={l.productId} onChange={(e) => chooseProduct(i, e.target.value)}><option value="">Expense only</option>{products.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select><input value={l.description} onChange={(e) => change(i, "description", e.target.value)} required/><select value={l.accountId} onChange={(e) => change(i, "accountId", e.target.value)}><option value="">Inventory</option>{expenseAccounts.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select><input type="number" min="0.001" step="0.001" value={l.quantity} onChange={(e) => change(i, "quantity", e.target.value)}/><input type="number" min="0" step="0.01" value={l.unitPrice} onChange={(e) => change(i, "unitPrice", e.target.value)}/><input type="number" min="0" max="100" step="0.01" value={l.gstRate} onChange={(e) => change(i, "gstRate", e.target.value)}/><b>{pkr.format(Number(l.quantity || 0) * Number(l.unitPrice || 0) * (1 + Number(l.gstRate || 0) / 100))}</b><button type="button" disabled={lines.length === 1} onClick={() => setLines(lines.filter((_, n) => n !== i))}><Trash2 size={15}/></button></div>)}</div>
      <button type="button" className="text-button" onClick={() => setLines([...lines, blank()])}><Plus size={15}/> Add line</button><div className="invoice-totals"><span>Subtotal <b>{pkr.format(totals.sub)}</b></span><span>Input GST <b>{pkr.format(totals.gst)}</b></span><span className="grand-total">Total <b>{pkr.format(totals.total)}</b></span></div><div className="form-actions"><button type="button" className="outline" onClick={() => setBillOpen(false)}>Cancel</button><button type="button" className="outline" disabled={busy} onClick={()=>saveBill(false)}>Save draft</button>{!importedDraft && <button className="primary" disabled={busy}>{busy ? "Saving..." : editingBillId ? "Update & post" : "Post bill"}</button>}</div>
    </form>}
    <div className="sales-table"><div className="purchase-row data-heading"><span>No.</span><span>Date</span><span>Supplier</span><span>Due</span><span>Total</span><span>Paid</span><span>Status</span><span>Actions</span></div>{bills.map((b) => <div className="purchase-row" key={b.id}><span className="code">BILL-{String(b.bill_number).padStart(6, "0")}</span><span>{b.bill_date}</span><span>{b.contacts?.name ?? "—"}</span><span>{b.due_date}</span><b>{b.status === "draft" ? "Draft" : pkr.format(Number(b.total))}</b><span>{pkr.format(Number(b.amount_paid))}</span><span className="status">{b.status}</span><span className="row-actions"><button type="button" title="View bill" aria-label={`View bill ${b.bill_number}`} onClick={()=>setViewingBillId(b.id)}><Eye size={14}/></button>{b.status==="draft"&&<button title="Edit draft" onClick={()=>editBill(b.id)}><Pencil size={14}/></button>}{["draft","posted"].includes(b.status)&&<button className="danger" title={b.status==="draft"?"Delete":"Void"} onClick={()=>removeOrVoidBill(b)}>{b.status==="draft"?<Trash2 size={14}/>:<RotateCcw size={14}/>}</button>}</span></div>)}</div>
    {viewingBillId && <PurchaseBillDetails key={`${companyId}:${viewingBillId}`} companyId={companyId} billId={viewingBillId} onClose={()=>setViewingBillId("")} onEdit={()=>{const id=viewingBillId;setViewingBillId("");void editBill(id);}}/>}
  </article>}{section === "returns" && <PurchaseDebitNotes companyId={companyId} onChanged={load}/>} {section === "orders" && <PurchaseOrders companyId={companyId} branches={branches} suppliers={suppliers} products={products} warehouses={warehouses} accounts={accounts} onConverted={load}/>}</div>;
}
