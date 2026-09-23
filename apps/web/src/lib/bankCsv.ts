export type ImportLine = { transaction_date: string; description: string; reference: string; debit: number; credit: number; external_id: string; source_row: number };

function csvRows(text: string) {
  const rows: string[][] = []; let row: string[] = []; let cell = ""; let quoted = false;
  for (let i = 0; i < text.length; i += 1) {
    const char = text[i];
    if (char === '"') {
      if (quoted && text[i + 1] === '"') { cell += '"'; i += 1; } else quoted = !quoted;
    } else if (char === "," && !quoted) { row.push(cell.trim()); cell = ""; }
    else if ((char === "\n" || char === "\r") && !quoted) {
      if (char === "\r" && text[i + 1] === "\n") i += 1;
      row.push(cell.trim()); if (row.some(Boolean)) rows.push(row); row = []; cell = "";
    } else cell += char;
  }
  row.push(cell.trim()); if (row.some(Boolean)) rows.push(row);
  return rows;
}

function normalizeHeader(value: string) { return value.toLowerCase().replace(/[^a-z0-9]/g, ""); }
function parseDate(value: string) {
  const clean = value.trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(clean)) return clean;
  const match = clean.match(/^(\d{1,2})[\/-](\d{1,2})[\/-](\d{4})$/);
  if (!match) throw new Error(`Invalid date: ${value}`);
  const [, day, month, year] = match;
  return `${year}-${month.padStart(2, "0")}-${day.padStart(2, "0")}`;
}
function parseAmount(value = "") {
  const clean = value.replace(/[(),\s]/g, "").replace(/PKR/gi, "");
  if (!clean) return 0;
  const number = Number(clean);
  if (!Number.isFinite(number)) throw new Error(`Invalid amount: ${value}`);
  return value.includes("(") ? -Math.abs(number) : number;
}

export function parseStatementCsv(text: string): ImportLine[] {
  const rows = csvRows(text); if (rows.length < 2) throw new Error("CSV needs a header and at least one transaction.");
  const headers = rows[0].map(normalizeHeader);
  const find = (...names: string[]) => headers.findIndex((h) => names.includes(h));
  const dateAt = find("date", "transactiondate", "valuedate");
  const descriptionAt = find("description", "narration", "details", "particulars");
  const referenceAt = find("reference", "ref", "transactionid", "chequeno");
  const externalAt = find("externalid", "bankid", "transactionid");
  const debitAt = find("debit", "withdrawal", "withdrawals");
  const creditAt = find("credit", "deposit", "deposits");
  const amountAt = find("amount", "transactionamount");
  const typeAt = find("type", "drcr", "transactiontype");
  if (dateAt < 0 || (debitAt < 0 && creditAt < 0 && amountAt < 0)) throw new Error("CSV must include Date and Debit/Credit columns, or Date and Amount.");
  return rows.slice(1).map((row, index) => {
    let debit = debitAt >= 0 ? Math.abs(parseAmount(row[debitAt])) : 0;
    let credit = creditAt >= 0 ? Math.abs(parseAmount(row[creditAt])) : 0;
    if (debitAt < 0 && creditAt < 0) {
      const amount = parseAmount(row[amountAt]); const kind = typeAt >= 0 ? (row[typeAt] || "").toLowerCase() : "";
      const isDebit = kind.startsWith("d") || kind.includes("withdraw") || amount < 0;
      debit = isDebit ? Math.abs(amount) : 0; credit = isDebit ? 0 : Math.abs(amount);
    }
    if ((debit > 0) === (credit > 0)) throw new Error(`Row ${index + 2} must contain exactly one debit or credit amount.`);
    return { transaction_date: parseDate(row[dateAt]), description: descriptionAt >= 0 ? row[descriptionAt] || "" : "", reference: referenceAt >= 0 ? row[referenceAt] || "" : "", external_id: externalAt >= 0 ? row[externalAt] || "" : "", debit, credit, source_row: index + 2 };
  });
}

export function dayDistance(a: string, b: string) { return Math.abs(new Date(a + "T00:00:00Z").getTime() - new Date(b + "T00:00:00Z").getTime()) / 86400000; }
