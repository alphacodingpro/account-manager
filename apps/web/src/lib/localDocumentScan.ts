import { supabase } from "./supabase";
import { extractBillFields, extractTableItems, readDocument, type ExtractedBill } from "./documentImport";

export async function scanSupplierDocument(file: File, companyId: string): Promise<ExtractedBill> {
  const url = import.meta.env.VITE_DOCUMENT_SCAN_URL?.replace(/\/$/, "");
  const supported = /\.(pdf|png|jpe?g|webp)$/i.test(file.name);
  if (!url || !supported) return extractBillFields(await readDocument(file));
  if (file.size > 12 * 1024 * 1024) throw new Error("Maximum file size is 12 MB.");
  if (/\.pdf$/i.test(file.name)) {
    const native = extractBillFields(await readDocument(file, true));
    const sum = native.items.reduce((total, item) => total + item.amount, 0);
    if (native.items.length && native.subtotal !== null && Math.abs(sum - native.subtotal) <= .02) return { ...native, engine: "PDF native text (no OCR substitution)" };
  }
  const { data, error } = await supabase.auth.getSession();
  if (error || !data.session) throw new Error("Sign in before scanning a document.");
  const body = new FormData(); body.append("file", file); body.append("company_id", companyId);
  const response = await fetch(`${url}/scan`, { method: "POST", body, headers: { Authorization: `Bearer ${data.session.access_token}` }, signal: AbortSignal.timeout(250000) });
  const result = await response.json();
  if (!response.ok) throw new Error(typeof result.detail === "string" ? result.detail : "Local scanner is unavailable. Try again shortly.");
  if (typeof result.text !== "string" || !Array.isArray(result.tables) || !result.tables.every((table: unknown) => Array.isArray(table) && table.every((row: unknown) => Array.isArray(row) && row.every((cell: unknown) => typeof cell === "string")))) throw new Error("Scanner returned an invalid document result.");
  const extracted = extractBillFields(result.text);
  const tables = result.tables as string[][][];
  const tableItems = extractTableItems(tables);
  const textItems = extracted.items;
  const errorFor = (items: typeof tableItems) => extracted.subtotal === null ? Infinity : Math.abs(items.reduce((sum, item) => sum + item.amount, 0) - extracted.subtotal);
  if (tableItems.length && (!textItems.length || errorFor(tableItems) < errorFor(textItems) || (errorFor(tableItems) === errorFor(textItems) && tableItems.length >= textItems.length))) {
    // Do not mix table and plain-text rows, which would double-count items.
    extracted.items = tableItems;
    extracted.warnings = extracted.warnings.filter((warning) => !warning.startsWith("No item rows") && !warning.startsWith("Detected item rows"));
    if (extracted.subtotal !== null && Math.abs(tableItems.reduce((sum, item) => sum + item.amount, 0) - extracted.subtotal) > .02) extracted.warnings.push("Scanned table does not match the printed subtotal. Check for missing rows.");
  }
  return { ...extracted, tables, engine: result.engine, warnings: [...extracted.warnings, ...(Array.isArray(result.warnings) ? result.warnings.filter((warning: unknown) => typeof warning === "string") : [])] };
}
