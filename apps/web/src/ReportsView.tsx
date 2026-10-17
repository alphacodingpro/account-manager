import { ListSearch, matchesRecord } from "./RecordTools";
import { useEffect, useState } from "react";
import { BarChart3, Download, Printer } from "lucide-react";
import { supabase } from "./lib/supabase";
import { downloadCsv, reportFilename, reportToCsv, type ExportRow } from "./lib/reportExport";
import "./ReportsView.css";
import { msgClass } from "./Modal";

type ReportName = "Trial Balance" | "Profit & Loss" | "Balance Sheet" | "Cash Flow" | "Receivable Aging" | "Payable Aging";
const pkr = new Intl.NumberFormat("en-PK", { style: "currency", currency: "PKR" });
const today = new Date().toISOString().slice(0, 10);
const yearStart = `${new Date().getFullYear()}-01-01`;
const asOfReports: ReportName[] = ["Balance Sheet", "Receivable Aging", "Payable Aging"];
const reportNames: ReportName[] = ["Trial Balance", "Profit & Loss", "Balance Sheet", "Cash Flow", "Receivable Aging", "Payable Aging"];

export default function ReportsView({ companyId }: { companyId: string }) {
  const [query,setQuery]=useState("");
  const [report, setReport] = useState<ReportName>("Trial Balance");
  const [from, setFrom] = useState(yearStart);
  const [to, setTo] = useState(today);
  const [rows, setRows] = useState<ExportRow[]>([]);
  const [message, setMessage] = useState("");
  const [loading, setLoading] = useState(false);

  async function load() {
    setMessage("");
    setLoading(true);
    const calls: Record<ReportName, () => ReturnType<typeof supabase.rpc>> = {
      "Trial Balance": () => supabase.rpc("get_trial_balance", { target_company: companyId, date_from: from, date_to: to }),
      "Profit & Loss": () => supabase.rpc("get_profit_loss", { target_company: companyId, date_from: from, date_to: to }),
      "Balance Sheet": () => supabase.rpc("get_balance_sheet", { target_company: companyId, as_of: to }),
      "Cash Flow": () => supabase.rpc("get_cash_flow", { target_company: companyId, date_from: from, date_to: to }),
      "Receivable Aging": () => supabase.rpc("get_receivable_aging", { target_company: companyId, as_of: to }),
      "Payable Aging": () => supabase.rpc("get_payable_aging", { target_company: companyId, as_of: to }),
    };
    const result = await calls[report]();
    if (result.error) {
      setRows([]);
      setMessage(result.error.message);
    } else setRows((result.data ?? []) as ExportRow[]);
    setLoading(false);
  }

  useEffect(() => { load(); }, [companyId, report]);
  const columns = rows.length ? Object.keys(rows[0]).filter((column) => column !== "sort_order") : [];
  const period = asOfReports.includes(report) ? `As of ${to}` : `${from} to ${to}`;
  function exportReport() {
    downloadCsv(reportFilename(report, from, to), reportToCsv(columns, rows));
  }

  return <div className="accounting-stack"><article className="panel data-panel">
    <div className="panel-head"><div><h3>Financial reports</h3><p>Posted double-entry data only</p></div><div className="report-actions"><button onClick={exportReport} disabled={!rows.length || loading} title="Download Excel-compatible CSV"><Download size={15}/>Export CSV</button><button onClick={() => window.print()} disabled={!rows.length || loading} title="Print or save as PDF"><Printer size={15}/>Print / PDF</button></div></div>
    <div className="report-print-heading"><strong>CloudLedger PK</strong><h1>{report}</h1><p className="report-period">{period}</p></div>
    <div className="report-toolbar"><select value={report} onChange={(e) => setReport(e.target.value as ReportName)}>{reportNames.map((name) => <option key={name}>{name}</option>)}</select><label>From<input type="date" value={from} onChange={(e) => setFrom(e.target.value)} disabled={asOfReports.includes(report)}/></label><label>To / as of<input type="date" value={to} onChange={(e) => setTo(e.target.value)}/></label><button className="primary" onClick={load} disabled={loading}>{loading ? "Loading…" : "Run report"}</button></div>
    <ListSearch value={query} onChange={setQuery}/>{query&&<p className="notice">Search filters the screen only. CSV and print contain the complete report.</p>}
    {message && <p className={msgClass(message)}>{message}</p>}
    {!rows.length ? <div className="mini-empty"><BarChart3/><p>{loading ? "Loading report…" : "No posted data for this report."}</p></div> : <div className="report-table" aria-label={`${report}, ${period}`}><div className="report-row data-heading" style={{ gridTemplateColumns: `repeat(${columns.length}, minmax(130px, 1fr))` }}>{columns.map((column) => <span key={column}>{column.replaceAll("_", " ")}</span>)}</div>{rows.map((row, index) => <div className={`report-row${matchesRecord(row,query)?"":" report-search-hidden"}`} key={index} style={{ gridTemplateColumns: `repeat(${columns.length}, minmax(130px, 1fr))` }}>{columns.map((column) => <span key={column}>{typeof row[column] === "number" || (column.includes("amount") || ["debit", "credit", "balance"].includes(column)) ? pkr.format(Number(row[column] ?? 0)) : String(row[column] ?? "—")}</span>)}</div>)}</div>}
  </article></div>;
}
