import { ListSearch, matchesRecord } from "./RecordTools";
import { useEffect, useState } from "react";
import { BarChart3, Download } from "lucide-react";
import { supabase } from "./lib/supabase";
import { downloadCsv, reportFilename, reportToCsv, type ExportRow } from "./lib/reportExport";
import "./ReportsView.css";
import { msgClass } from "./Modal";
import PdfButton from "./PdfButton";
import { addReportTotals, type ReportRow } from "./lib/reportTotals";
import { getPdfCompany, pdfDate, pdfMoney, pdfPeriod, type PdfSpec } from "./lib/pdfExport";

type ReportName = "Trial Balance" | "Profit & Loss" | "Balance Sheet" | "Cash Flow" | "Receivable Aging" | "Payable Aging" | "GST Summary" | "General Ledger";
const pkr = new Intl.NumberFormat("en-PK", { style: "currency", currency: "PKR" });
const today = new Date().toISOString().slice(0, 10);
const yearStart = `${new Date().getFullYear()}-01-01`;
const asOfReports: ReportName[] = ["Balance Sheet", "Receivable Aging", "Payable Aging"];
const reportNames: ReportName[] = ["Trial Balance", "Profit & Loss", "Balance Sheet", "Cash Flow", "Receivable Aging", "Payable Aging", "GST Summary", "General Ledger"];

export default function ReportsView({ companyId }: { companyId: string }) {
  const [query,setQuery]=useState("");
  const [report, setReport] = useState<ReportName>("Trial Balance");
  const [from, setFrom] = useState(yearStart);
  const [to, setTo] = useState(today);
  const [rows, setRows] = useState<ExportRow[]>([]);
  const [message, setMessage] = useState("");
  const [loading, setLoading] = useState(false);
  const [accountId, setAccountId] = useState("");
  const [accountList, setAccountList] = useState<{ id: string; code: string; name: string }[]>([]);
  useEffect(() => { supabase.from("accounts").select("id,code,name").eq("company_id", companyId).order("code").then((r) => setAccountList((r.data ?? []) as { id: string; code: string; name: string }[])); }, [companyId]);

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
      "GST Summary": () => supabase.rpc("get_gst_summary", { target_company: companyId, date_from: from, date_to: to }),
      "General Ledger": () => supabase.rpc("get_account_ledger", { target_company: companyId, date_from: from, date_to: to, target_account: accountId || null }),
    };
    const result = await calls[report]();
    if (result.error) {
      setRows([]);
      setMessage(result.error.message);
    } else setRows(addReportTotals(report, (result.data ?? []) as ReportRow[]) as ExportRow[]);
    setLoading(false);
  }

  useEffect(() => { load(); }, [companyId, report]);
  const columns = rows.length ? Object.keys(rows[0]).filter((column) => column !== "sort_order" && !column.startsWith("__")) : [];
  const period = asOfReports.includes(report) ? `As of ${to}` : `${from} to ${to}`;
  const isMoney = (column: string, value: unknown) => typeof value === "number" || column.includes("amount") || column.endsWith("_gst") || column.endsWith("_value") || column.endsWith("_payable") || ["debit", "credit", "balance"].includes(column);
  const titleCase = (column: string) => column.replaceAll("_", " ").replace(/\b\w/g, (c) => c.toUpperCase());
  function buildReportPdf(): PdfSpec {
    const moneyColumns = columns.map((column) => rows.some((row) => isMoney(column, row[column])));
    return {
      title: report,
      subtitle: asOfReports.includes(report) ? `As of ${pdfDate(to)}` : pdfPeriod(from, to),
      columns: columns.map((column, i) => ({ header: titleCase(column), align: moneyColumns[i] ? "right" : "left" })),
      rows: rows.map((row) => columns.map((column, i) => moneyColumns[i] && row[column] !== null && row[column] !== "" ? pdfMoney(row[column]) : String(row[column] ?? "-"))),
      orientation: columns.length > 5 ? "landscape" : "portrait",
      footnote: "Posted double-entry data only",
      filename: reportFilename(report, from, to).replace(/\.csv$/i, ""),
    };
  }
  function exportReport() {
    downloadCsv(reportFilename(report, from, to), reportToCsv(columns, rows));
  }

  return <div className="accounting-stack"><article className="panel data-panel">
    <div className="panel-head"><div><h3>Financial reports</h3><p>Posted double-entry data only</p></div><div className="report-actions"><button onClick={exportReport} disabled={!rows.length || loading} title="Download Excel-compatible CSV"><Download size={15}/>Export CSV</button><PdfButton className="" label="Download PDF" build={buildReportPdf} disabled={!rows.length || loading} title="Download a professional PDF with your company letterhead"/></div></div>
    <div className="report-print-heading"><strong>{getPdfCompany()?.name ?? "CloudLedger PK"}</strong><h1>{report}</h1><p className="report-period">{period}</p></div>
    <div className="report-toolbar"><select value={report} onChange={(e) => setReport(e.target.value as ReportName)}>{reportNames.map((name) => <option key={name}>{name}</option>)}</select>{report === "General Ledger" && <label>Account<select value={accountId} onChange={(e) => setAccountId(e.target.value)}><option value="">All accounts</option>{accountList.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select></label>}<label>From<input type="date" value={from} onChange={(e) => setFrom(e.target.value)} disabled={asOfReports.includes(report)}/></label><label>To / as of<input type="date" value={to} onChange={(e) => setTo(e.target.value)}/></label><button className="primary" onClick={load} disabled={loading}>{loading ? "Loading…" : "Run report"}</button></div>
    <ListSearch value={query} onChange={setQuery}/>{query&&<p className="notice">Search filters the screen only. CSV and PDF contain the complete report.</p>}
    {message && <p className={msgClass(message)}>{message}</p>}
    {!rows.length ? <div className="mini-empty"><BarChart3/><p>{loading ? "Loading report…" : "No posted data for this report."}</p></div> : <div className="report-table" aria-label={`${report}, ${period}`}><div className="report-row data-heading" style={{ gridTemplateColumns: `repeat(${columns.length}, minmax(130px, 1fr))` }}>{columns.map((column) => <span key={column} className={rows.some((row) => isMoney(column, row[column])) ? "num" : ""}>{column.replaceAll("_", " ")}</span>)}</div>{rows.map((row, index) => <div className={`report-row${matchesRecord(row,query)?"":" report-search-hidden"}${row.__total ? " report-total" : ""}`} key={index} style={{ gridTemplateColumns: `repeat(${columns.length}, minmax(130px, 1fr))` }}>{columns.map((column) => { const money = rows.some((r) => isMoney(column, r[column])); const raw = row[column]; return <span key={column} className={money ? "num" : ""}>{money && raw !== "" && raw !== null && raw !== undefined ? (Number(raw) === 0 ? "—" : pkr.format(Number(raw))) : String(raw === "" || raw === null || raw === undefined ? (money ? "" : "—") : raw)}</span>; })}</div>)}</div>}
  </article></div>;
}
