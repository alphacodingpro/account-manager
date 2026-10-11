import { useEffect, useState } from "react";
import { ArrowRightLeft, Package, Pencil, Plus, SlidersHorizontal, Trash2, X } from "lucide-react";
import { supabase } from "./lib/supabase";
import "./InventoryView.css";
type Product = {
  id: string;
  sku: string;
  name: string;
  is_service: boolean;
  unit: string;
  sale_price: number;
  purchase_price: number;
  average_cost: number;
  gst_rate: number;
  quantity_on_hand: number;
  reorder_level: number;
  active: boolean;
};
type Warehouse = { id: string; name: string; branch_id: string };
type Movement = { id: string; movement_type: string; movement_date: string; quantity: number; reference: string | null; products: { name: string } | null; warehouses: { name: string } | null };
type StockBalance = { warehouse_id: string; warehouse_name: string; product_id: string; sku: string; product_name: string; quantity: number; average_cost: number; stock_value: number };
const pkr = new Intl.NumberFormat("en-PK", {
  style: "currency",
  currency: "PKR",
});
export default function InventoryView({ companyId, section = "products" }: { companyId: string; section?: "products" | "stock" | "adjustments" | "transfers" | "movements" }) {
  const [products, setProducts] = useState<Product[]>([]);
  const [warehouses, setWarehouses] = useState<Warehouse[]>([]);
  const [movements, setMovements] = useState<Movement[]>([]);
  const [stockBalances, setStockBalances] = useState<StockBalance[]>([]);
  const [open, setOpen] = useState(false);
  const [editingId, setEditingId] = useState("");
  const [message, setMessage] = useState("");
  const [stockBusy, setStockBusy] = useState(false);
  const [adjustment, setAdjustment] = useState({ productId: "", warehouseId: "", quantity: "", direction: "increase", reference: "" });
  const [transfer, setTransfer] = useState({ productId: "", sourceId: "", destinationId: "", quantity: "", reference: "" });
  const [form, setForm] = useState({
    sku: "",
    name: "",
    unit: "each",
    sale_price: "",
    purchase_price: "",
    gst_rate: "0",
    reorder_level: "0",
    is_service: false,
  });
  async function load() {
    const [productResult, warehouseResult, movementResult, balanceResult] = await Promise.all([
      supabase.from("products").select("*").eq("company_id", companyId).order("name"),
      supabase.from("warehouses").select("id,name,branch_id").eq("company_id", companyId).eq("active", true).order("name"),
      supabase.from("stock_movements").select("id,movement_type,movement_date,quantity,reference,products(name),warehouses(name)").eq("company_id", companyId).order("created_at", { ascending: false }).limit(12),
      supabase.rpc("get_inventory_stock", { target_company: companyId }),
    ]);
    const error = productResult.error ?? warehouseResult.error ?? movementResult.error ?? balanceResult.error;
    if (error) setMessage(error.message);
    else {
      setProducts((productResult.data ?? []) as Product[]);
      setWarehouses((warehouseResult.data ?? []) as Warehouse[]);
      setMovements((movementResult.data ?? []) as unknown as Movement[]);
      setStockBalances((balanceResult.data ?? []) as StockBalance[]);
    }
  }
  useEffect(() => {
    load();
  }, [companyId]);
  async function save(e: React.FormEvent) {
    e.preventDefault();
    const payload = {
        company_id: companyId,
        sku: form.sku.trim(),
        name: form.name.trim(),
        unit: form.unit,
        sale_price: Number(form.sale_price || 0),
        purchase_price: Number(form.purchase_price || 0),
        gst_rate: Number(form.gst_rate || 0),
        reorder_level: Number(form.reorder_level || 0),
        is_service: form.is_service,
      };
    const result = editingId
      ? await supabase.from("products").update(payload).eq("id", editingId).eq("company_id", companyId)
      : await supabase.from("products").insert(payload);
    const { error } = result;
    if (error) setMessage(error.message);
    else {
      setMessage(editingId ? "Product updated successfully." : "Product created successfully.");
      setOpen(false);
      setEditingId("");
      setForm({
        sku: "",
        name: "",
        unit: "each",
        sale_price: "",
        purchase_price: "",
        gst_rate: "0",
        reorder_level: "0",
        is_service: false,
      });
      load();
    }
  }
  function edit(product: Product) {
    setEditingId(product.id);
    setForm({ sku: product.sku, name: product.name, unit: product.unit, sale_price: String(product.sale_price), purchase_price: String(product.purchase_price), gst_rate: String(product.gst_rate), reorder_level: String(product.reorder_level), is_service: product.is_service });
    setOpen(true);
    setMessage("");
  }
  async function remove(product: Product) {
    if (!confirm(`Delete ${product.name}? This is only allowed when it has never been used in a transaction.`)) return;
    const result = await supabase.from("products").delete().eq("id", product.id).eq("company_id", companyId);
    if (result.error) setMessage("This item is already used in a transaction and cannot be deleted. Edit it or mark it inactive instead.");
    else { setMessage("Product deleted successfully."); await load(); }
  }
  async function saveAdjustment(e: React.FormEvent) {
    e.preventDefault(); setStockBusy(true); setMessage("");
    const { error } = await supabase.rpc("record_stock_adjustment", { target_company: companyId, target_warehouse: adjustment.warehouseId, target_product: adjustment.productId, target_quantity: Number(adjustment.quantity), target_increase: adjustment.direction === "increase", target_reference: adjustment.reference.trim() });
    setMessage(error?.message ?? "Stock adjustment recorded successfully.");
    if (!error) { setAdjustment({ productId: "", warehouseId: "", quantity: "", direction: "increase", reference: "" }); await load(); }
    setStockBusy(false);
  }
  async function saveTransfer(e: React.FormEvent) {
    e.preventDefault(); setStockBusy(true); setMessage("");
    const { error } = await supabase.rpc("record_stock_transfer", { target_company: companyId, source_warehouse: transfer.sourceId, destination_warehouse: transfer.destinationId, target_product: transfer.productId, target_quantity: Number(transfer.quantity), target_reference: transfer.reference.trim() });
    setMessage(error?.message ?? "Warehouse transfer recorded successfully.");
    if (!error) { setTransfer({ productId: "", sourceId: "", destinationId: "", quantity: "", reference: "" }); await load(); }
    setStockBusy(false);
  }
  return (
    <div className="accounting-stack inventory-view">
      {message && <p role="status" className={message.includes("success") ? "notice" : "alert"}>{message}</p>}
      {section === "products" && <article className="panel data-panel">
        <div className="panel-head">
          <div>
            <h3>Products and services</h3>
            <p>Sale prices, GST and current stock</p>
          </div>
          <button
            className="primary small-button"
            onClick={() => { setOpen((v) => !v); setEditingId(""); setForm({sku:"",name:"",unit:"each",sale_price:"",purchase_price:"",gst_rate:"0",reorder_level:"0",is_service:false}); }}
          >
            {open ? <X size={16} /> : <Plus size={16} />} {editingId ? "Cancel edit" : "New item"}
          </button>
        </div>
        {open && (
          <form className="product-form" onSubmit={save}>
            <label>
              SKU
              <input
                value={form.sku}
                onChange={(e) => setForm({ ...form, sku: e.target.value })}
                placeholder="CAM-001"
                required
              />
            </label>
            <label>
              Name
              <input
                value={form.name}
                onChange={(e) => setForm({ ...form, name: e.target.value })}
                placeholder="IP Camera"
                required
              />
            </label>
            <label>
              Unit
              <input
                value={form.unit}
                onChange={(e) => setForm({ ...form, unit: e.target.value })}
                placeholder="each"
                required
              />
            </label>
            <label>
              Sale price
              <input
                type="number"
                min="0"
                step="0.01"
                value={form.sale_price}
                onChange={(e) =>
                  setForm({ ...form, sale_price: e.target.value })
                }
                required
              />
            </label>
            <label>
              Purchase price
              <input
                type="number"
                min="0"
                step="0.01"
                value={form.purchase_price}
                onChange={(e) =>
                  setForm({ ...form, purchase_price: e.target.value })
                }
              />
            </label>
            <label>
              GST %
              <input
                type="number"
                min="0"
                max="100"
                step="0.01"
                value={form.gst_rate}
                onChange={(e) => setForm({ ...form, gst_rate: e.target.value })}
              />
            </label>
            <label>
              Reorder level
              <input
                type="number"
                min="0"
                step="0.001"
                value={form.reorder_level}
                onChange={(e) =>
                  setForm({ ...form, reorder_level: e.target.value })
                }
              />
            </label>
            <label className="checkbox">
              <input
                type="checkbox"
                checked={form.is_service}
                onChange={(e) =>
                  setForm({ ...form, is_service: e.target.checked })
                }
              />{" "}
              This is a service
            </label>
            <button className="primary">{editingId ? "Update item" : "Save item"}</button>
          </form>
        )}{" "}
        {products.length === 0 ? (
          <div className="mini-empty">
            <Package />
            <p>No products or services yet.</p>
          </div>
        ) : (
          <div className="inventory-table">
            <div className="inventory-row data-heading">
              <span>SKU</span>
              <span>Item</span>
              <span>Type</span>
              <span>Sale price</span>
              <span>Avg. cost</span>
              <span>Stock</span>
              <span>Actions</span>
            </div>
            {products.map((p) => (
              <div className="inventory-row" key={p.id}>
                <span className="code">{p.sku}</span>
                <span>
                  <b>{p.name}</b>
                  <small>{p.unit}</small>
                </span>
                <span>{p.is_service ? "Service" : "Product"}</span>
                <span>{pkr.format(p.sale_price)}</span>
                <span>{p.is_service ? "—" : pkr.format(p.average_cost)}</span>
                <span
                  className={
                    !p.is_service && p.quantity_on_hand <= p.reorder_level
                      ? "low-stock"
                      : ""
                  }
                >
                  {p.is_service ? "—" : p.quantity_on_hand}
                </span>
                <span className="row-actions"><button title="Edit" onClick={() => edit(p)}><Pencil size={14}/></button><button className="danger" title="Delete" onClick={() => remove(p)}><Trash2 size={14}/></button></span>
              </div>
            ))}
          </div>
        )}
      </article>}
      {section === "stock" && <article className="panel data-panel">
        <div className="panel-head"><div><h3>Warehouse stock ledger</h3><p>Live quantity and weighted-average valuation</p></div><Package /></div>
        {stockBalances.length === 0 ? <div className="mini-empty"><Package/><p>No warehouse stock movements yet.</p></div> : <div className="inventory-table inventory-stock">
          <div className="inventory-row data-heading"><span>Warehouse</span><span>SKU</span><span>Item</span><span>Quantity</span><span>Average cost</span><span>Stock value</span><span></span></div>
          {stockBalances.map((row) => <div className="inventory-row" key={`${row.warehouse_id}-${row.product_id}`}><span><b>{row.warehouse_name}</b></span><span className="code">{row.sku}</span><span>{row.product_name}</span><span>{row.quantity}</span><span>{pkr.format(row.average_cost)}</span><span><b>{pkr.format(row.stock_value)}</b></span><span></span></div>)}
        </div>}
      </article>}
      {["adjustments", "transfers", "movements"].includes(section) && <article className="panel data-panel">
        <div className="panel-head"><div><h3>{section === "adjustments" ? "Stock adjustments" : section === "transfers" ? "Warehouse transfers" : "Stock movements"}</h3><p>{section === "movements" ? "Recent inventory movement history" : "Record inventory changes with an audit reference"}</p></div><SlidersHorizontal /></div>
        {section === "adjustments" && <form className="product-form" onSubmit={saveAdjustment}>
          <label>Product<select value={adjustment.productId} onChange={(e) => setAdjustment({ ...adjustment, productId: e.target.value })} required><option value="">Select product</option>{products.filter((p) => !p.is_service && p.active).map((p) => <option key={p.id} value={p.id}>{p.sku} · {p.name} ({p.quantity_on_hand})</option>)}</select></label>
          <label>Warehouse<select value={adjustment.warehouseId} onChange={(e) => setAdjustment({ ...adjustment, warehouseId: e.target.value })} required><option value="">Select warehouse</option>{warehouses.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}</select></label>
          <label>Direction<select value={adjustment.direction} onChange={(e) => setAdjustment({ ...adjustment, direction: e.target.value })}><option value="increase">Stock in</option><option value="decrease">Stock out</option></select></label>
          <label>Quantity<input type="number" min="0.001" step="0.001" value={adjustment.quantity} onChange={(e) => setAdjustment({ ...adjustment, quantity: e.target.value })} required/></label>
          <label>Reference<input value={adjustment.reference} onChange={(e) => setAdjustment({ ...adjustment, reference: e.target.value })} placeholder="Count sheet / reason" required/></label>
          <button className="primary" disabled={stockBusy}><SlidersHorizontal size={16}/>{stockBusy ? "Recording…" : "Record adjustment"}</button>
        </form>}
        {section === "transfers" && warehouses.length > 1 && <form className="product-form" onSubmit={saveTransfer}>
          <label>Product<select value={transfer.productId} onChange={(e) => setTransfer({ ...transfer, productId: e.target.value })} required><option value="">Select product</option>{products.filter((p) => !p.is_service && p.active).map((p) => <option key={p.id} value={p.id}>{p.sku} · {p.name}</option>)}</select></label>
          <label>From<select value={transfer.sourceId} onChange={(e) => setTransfer({ ...transfer, sourceId: e.target.value })} required><option value="">Source warehouse</option>{warehouses.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}</select></label>
          <label>To<select value={transfer.destinationId} onChange={(e) => setTransfer({ ...transfer, destinationId: e.target.value })} required><option value="">Destination warehouse</option>{warehouses.filter((w) => w.id !== transfer.sourceId).map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}</select></label>
          <label>Quantity<input type="number" min="0.001" step="0.001" value={transfer.quantity} onChange={(e) => setTransfer({ ...transfer, quantity: e.target.value })} required/></label>
          <label>Reference<input value={transfer.reference} onChange={(e) => setTransfer({ ...transfer, reference: e.target.value })} placeholder="Transfer note number" required/></label>
          <button className="primary" disabled={stockBusy}><ArrowRightLeft size={16}/>{stockBusy ? "Transferring…" : "Transfer stock"}</button>
        </form>}
        {section === "transfers" && warehouses.length < 2 && <div className="mini-empty"><ArrowRightLeft/><p>At least two active warehouses are required for a stock transfer.</p></div>}
        {section === "movements" && <div className="inventory-table inventory-movements">
          <div className="inventory-row data-heading"><span>Date</span><span>Item</span><span>Warehouse</span><span>Movement</span><span>Quantity</span><span>Reference</span><span></span></div>
          {movements.map((movement) => <div className="inventory-row" key={movement.id}><span>{new Date(movement.movement_date).toLocaleDateString("en-PK")}</span><span><b>{movement.products?.name ?? "Product"}</b></span><span>{movement.warehouses?.name ?? "Warehouse"}</span><span>{movement.movement_type.replaceAll("_", " ")}</span><span>{movement.quantity}</span><span>{movement.reference ?? "—"}</span><span></span></div>)}
        </div>}
      </article>}
    </div>
  );
}
