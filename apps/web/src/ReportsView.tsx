import { useEffect, useState } from "react";
import { BarChart3 } from "lucide-react";
import { supabase } from "./lib/supabase";

type ReportName = "Trial Balance" | "Profit & Loss" | "Balance Sheet" | "Receivable Aging" | "Payable Aging";
type Row = Record<string, string | number | null>;
const pkr = new Intl.NumberFormat("en-PK", { style: "currency", currency: "PKR" });
const today = new Date().toISOString().slice(0, 10);
const yearStart = `${new Date().getFullYear()}-01-01`;

export default function ReportsView({ companyId }: { companyId: string }) {
  const [report, setReport] = useState<ReportName>("Trial Balance");
  const [from, setFrom] = useState(yearStart);
  const [to, setTo] = useState(today);
  const [rows, setRows] = useState<Row[]>([]);
  const [message, setMessage] = useState("");
  async function load() {
    setMessage("");
    const calls: Record<ReportName, () => ReturnType<typeof supabase.rpc>> = {
      "Trial Balance": () => supabase.rpc("get_trial_balance", { target_company: companyId, date_from: from, date_to: to }),
      "Profit & Loss": () => supabase.rpc("get_profit_loss", { target_company: companyId, date_from: from, date_to: to }),
      "Balance Sheet": () => supabase.rpc("get_balance_sheet", { target_company: companyId, as_of: to }),
      "Receivable Aging": () => supabase.rpc("get_receivable_aging", { target_company: companyId, as_of: to }),
      "Payable Aging": () => supabase.rpc("get_payable_aging", { target_company: companyId, as_of: to }),
    };
    const result = await calls[report]();
    if (result.error) setMessage(result.error.message); else setRows((result.data ?? []) as Row[]);
  }
  useEffect(() => { load(); }, [companyId, report]);
  const columns = rows.length ? Object.keys(rows[0]) : [];
  return <div className="accounting-stack"><article className="panel data-panel">
    <div className="panel-head"><div><h3>Financial reports</h3><p>Posted double-entry data only</p></div></div>
    <div className="report-toolbar"><select value={report} onChange={(e) => setReport(e.target.value as ReportName)}>{["Trial Balance", "Profit & Loss", "Balance Sheet", "Receivable Aging", "Payable Aging"].map((x) => <option key={x}>{x}</option>)}</select><label>From<input type="date" value={from} onChange={(e) => setFrom(e.target.value)} disabled={["Balance Sheet", "Receivable Aging", "Payable Aging"].includes(report)}/></label><label>To / as of<input type="date" value={to} onChange={(e) => setTo(e.target.value)}/></label><button className="primary" onClick={load}>Run report</button></div>
    {message && <p className="alert">{message}</p>}
    {!rows.length ? <div className="mini-empty"><BarChart3/><p>No posted data for this report.</p></div> : <div className="report-table"><div className="report-row data-heading" style={{ gridTemplateColumns: `repeat(${columns.length}, minmax(130px, 1fr))` }}>{columns.map((c) => <span key={c}>{c.replaceAll("_", " ")}</span>)}</div>{rows.map((row, i) => <div className="report-row" key={i} style={{ gridTemplateColumns: `repeat(${columns.length}, minmax(130px, 1fr))` }}>{columns.map((c) => <span key={c}>{typeof row[c] === "number" || (c.includes("amount") || ["debit", "credit", "balance"].includes(c)) ? pkr.format(Number(row[c] ?? 0)) : String(row[c] ?? "—")}</span>)}</div>)}</div>}
  </article></div>;
}
