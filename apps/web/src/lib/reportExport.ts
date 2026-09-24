export type ExportRow = Record<string, string | number | null>;

function csvCell(value: string | number | null) {
  let text = value == null ? "" : String(value);
  if (/^[=+\-@]/.test(text)) text = `'${text}`;
  return `"${text.replaceAll('"', '""')}"`;
}

export function reportToCsv(columns: string[], rows: ExportRow[]) {
  const heading = columns.map((column) => csvCell(column.replaceAll("_", " "))).join(",");
  const body = rows.map((row) => columns.map((column) => csvCell(row[column])).join(","));
  return `\uFEFF${[heading, ...body].join("\r\n")}`;
}

export function reportFilename(report: string, from: string, to: string) {
  const slug = report.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
  return `cloudledger-${slug}-${from}-to-${to}.csv`;
}

export function downloadCsv(filename: string, content: string) {
  const url = URL.createObjectURL(new Blob([content], { type: "text/csv;charset=utf-8" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  link.click();
  URL.revokeObjectURL(url);
}
