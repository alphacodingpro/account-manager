import { useEffect, useState } from "react";
import { Package, Plus, X } from "lucide-react";
import { supabase } from "./lib/supabase";
type Product = {
  id: string;
  sku: string;
  name: string;
  is_service: boolean;
  unit: string;
  sale_price: number;
  purchase_price: number;
  gst_rate: number;
  quantity_on_hand: number;
  reorder_level: number;
  active: boolean;
};
const pkr = new Intl.NumberFormat("en-PK", {
  style: "currency",
  currency: "PKR",
});
export default function InventoryView({ companyId }: { companyId: string }) {
  const [products, setProducts] = useState<Product[]>([]);
  const [open, setOpen] = useState(false);
  const [message, setMessage] = useState("");
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
    const { data, error } = await supabase
      .from("products")
      .select("*")
      .eq("company_id", companyId)
      .order("name");
    if (error) setMessage(error.message);
    else setProducts((data ?? []) as Product[]);
  }
  useEffect(() => {
    load();
  }, [companyId]);
  async function save(e: React.FormEvent) {
    e.preventDefault();
    const { error } = await supabase
      .from("products")
      .insert({
        company_id: companyId,
        sku: form.sku.trim(),
        name: form.name.trim(),
        unit: form.unit,
        sale_price: Number(form.sale_price || 0),
        purchase_price: Number(form.purchase_price || 0),
        gst_rate: Number(form.gst_rate || 0),
        reorder_level: Number(form.reorder_level || 0),
        is_service: form.is_service,
      });
    if (error) setMessage(error.message);
    else {
      setMessage("Product created successfully.");
      setOpen(false);
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
  return (
    <div className="accounting-stack">
      <article className="panel data-panel">
        <div className="panel-head">
          <div>
            <h3>Products and services</h3>
            <p>Sale prices, GST and current stock</p>
          </div>
          <button
            className="primary small-button"
            onClick={() => setOpen((v) => !v)}
          >
            {open ? <X size={16} /> : <Plus size={16} />} New item
          </button>
        </div>
        {message && (
          <p className={message.includes("success") ? "notice" : "alert"}>
            {message}
          </p>
        )}
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
            <button className="primary">Save item</button>
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
              <span>GST</span>
              <span>Stock</span>
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
                <span>{p.gst_rate}%</span>
                <span
                  className={
                    !p.is_service && p.quantity_on_hand <= p.reorder_level
                      ? "low-stock"
                      : ""
                  }
                >
                  {p.is_service ? "—" : p.quantity_on_hand}
                </span>
              </div>
            ))}
          </div>
        )}
      </article>
    </div>
  );
}
