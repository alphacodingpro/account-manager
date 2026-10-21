/** Adds the total lines a finished financial statement needs (Trial Balance, Profit & Loss, Balance Sheet). */
export type ReportRow = Record<string, unknown>;
const n = (value: unknown) => Number(value ?? 0) || 0;
const round = (value: number) => Math.round(value * 100) / 100;

function line(label: string, values: Record<string, number>): ReportRow {
  return { account_code: "", account_name: label, ...values, __total: true };
}

export function addReportTotals(report: string, rows: ReportRow[]): ReportRow[] {
  if (!rows.length) return rows;
  const sum = (category: string) => round(rows.filter((r) => r.category === category).reduce((total, r) => total + n(r.amount), 0));
  if (report === "Trial Balance") {
    const keys = Object.keys(rows[0]);
    const total: ReportRow = Object.fromEntries(keys.map((k) => [k, ""]));
    total.account_name = "Total";
    total.debit = round(rows.reduce((t, r) => t + n(r.debit), 0));
    total.credit = round(rows.reduce((t, r) => t + n(r.credit), 0));
    return [...rows, { ...total, __total: true }];
  }
  if (report === "Profit & Loss" && rows.some((r) => "category" in r)) {
    const income = sum("income"), expense = sum("expense");
    return [...rows, line("Total income", { amount: income }), line("Total expenses", { amount: expense }), line(income - expense >= 0 ? "Net profit" : "Net loss", { amount: round(income - expense) })];
  }
  if (report === "Balance Sheet" && rows.some((r) => "category" in r)) {
    const assets = sum("asset"), liabilities = sum("liability"), equity = sum("equity");
    return [...rows, line("Total assets", { amount: assets }), line("Total liabilities", { amount: liabilities }), line("Total equity", { amount: equity }), line("Total liabilities and equity", { amount: round(liabilities + equity) })];
  }
  if (report === "GST Summary") {
    const sumOf = (key: string) => round(rows.reduce((total, r) => total + n(r[key]), 0));
    const total: ReportRow = Object.fromEntries(Object.keys(rows[0]).map((k) => [k, ""]));
    total.period = "Total";
    for (const key of ["sales_value", "output_gst", "purchase_value", "input_gst", "net_gst_payable"]) total[key] = sumOf(key);
    return [...rows, { ...total, __total: true }];
  }
  return rows;
}
