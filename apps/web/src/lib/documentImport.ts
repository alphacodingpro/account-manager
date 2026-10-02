export type ExtractedBill = {
  text: string;
  supplier: string;
  invoiceDate: string;
  reference: string;
  subtotal: number | null;
  gst: number | null;
  total: number | null;
  items: ExtractedItem[];
  warnings: string[];
  tables?: string[][][];
  engine?: string;
};

export type ExtractedItem = { description: string; quantity: number; unitPrice: number; amount: number };

export function extractTableItems(tables: string[][][]): ExtractedItem[] {
  const items: ExtractedItem[] = [];
  for (const table of tables) {
    const headerIndex = table.findIndex((row) => row.some((cell) => /^(?:qty|quantity)\b/i.test(cell.trim())) && row.some((cell) => /(?:description|item|product)/i.test(cell)));
    if (headerIndex < 0) continue;
    const header = table[headerIndex];
    const descriptionIndex = header.findIndex((cell) => /(?:description|item|product)/i.test(cell));
    const quantityIndex = header.findIndex((cell) => /^(?:qty|quantity)\b/i.test(cell.trim()));
    const priceIndex = header.findIndex((cell) => /(?:price|rate|unit cost)/i.test(cell));
    const amountIndex = header.findIndex((cell) => /^(?:amount|total|line total)\b/i.test(cell.trim()));
    if ([descriptionIndex, quantityIndex, priceIndex, amountIndex].some((i) => i < 0)) continue;
    const numeric = (cell: string) => {
      const value = cell.replace(/^(?:PKR|Rs\.?|₨|₹)\s*/i, "").trim();
      return /^(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d+)?$/.test(value) ? Number(value.replace(/,/g, "")) : NaN;
    };
    for (const row of table.slice(headerIndex + 1)) {
      const description = row[descriptionIndex]?.trim();
      if (!description || /^(?:total|sub\s*total|discount|gst|tax)\b/i.test(description)) continue;
      if ([quantityIndex, priceIndex, amountIndex].some((index) => !row[index]?.trim())) continue;
      const quantity = numeric(row[quantityIndex]), unitPrice = numeric(row[priceIndex]), printed = numeric(row[amountIndex]);
      if (![quantity, unitPrice, printed].every(Number.isFinite) || quantity <= 0 || unitPrice < 0 || printed < 0 || Math.abs(Math.round(quantity * unitPrice * 100) / 100 - printed) > .01) continue;
      items.push({ description, quantity, unitPrice, amount: printed });
    }
  }
  return items;
}

const amount = (value: string) => {
  const parsed = Number(value.replace(/[,\s]/g, ""));
  return Number.isFinite(parsed) && parsed >= 0 ? Math.round(parsed * 100) / 100 : null;
};

function labelledAmount(lines: string[], pattern: RegExp, lastValue = false): number | null {
  for (const line of [...lines].reverse()) {
    const label = line.match(pattern);
    if (!label) continue;
    const tail = line.slice((label.index ?? 0) + label[0].length);
    const values = [...tail.matchAll(/\d[\d,]*(?:\.\d{1,2})?/g)].filter((match) => !/^\s*%/.test(tail.slice((match.index ?? 0) + match[0].length)));
    if (values.length) return amount(values[lastValue ? values.length - 1 : 0][0]);
  }
  return null;
}

function dateFrom(text: string): string {
  const match = text.match(/(?:(?:invoice|bill|issue)\s*)?date\s*[:#-]?\s*(\d{1,4}[./-]\d{1,2}[./-]\d{1,4})/i);
  if (!match) return "";
  const parts = match[1].split(/[./-]/).map(Number);
  const [year, month, day] = parts[0] > 1900 ? parts : [parts[2], parts[1], parts[0]];
  const valid = new Date(Date.UTC(year, month - 1, day));
  return valid.getUTCFullYear() === year && valid.getUTCMonth() === month - 1 && valid.getUTCDate() === day
    ? `${year}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}` : "";
}

// Reassemble wrapped descriptions and serial-number continuation rows before
// accepting an item. Printed quantity × price must still match its amount.
export function extractItemRows(text: string): ExtractedItem[] {
  const items: ExtractedItem[] = [];
  const numeric = "(\\d[\\d,]*(?:\\.\\d{1,2})?)";
  const tail = `(\\d+(?:\\.\\d{1,3})?)\\s+(?:PKR|Rs\\.?|₨)?\\s*${numeric}\\s+(?:PKR|Rs\\.?|₨)?\\s*${numeric}`;
  const fullRow = new RegExp(`^(.+?)\\s+${tail}$`, "i");
  const valuesRow = new RegExp(`^(?:\\d+[.)]?\\s+)?${tail}$`, "i");
  let pendingDescription = "";
  let inTable = false;
  let attachSerial = false;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.replace(/\s+/g, " ").trim();
    if (!line) continue;
    if (/\b(?:item name|description)\b.*\b(?:quantity|qty|amount)\b/i.test(line)) { inTable = true; pendingDescription = ""; continue; }
    if (/^(?:sub\s*total|grand\s*total|invoice\s*(?:total|amount)|total(?:\s|:|$)|amount due|total payable|balance|discount|sales tax|gst|vat)\b/i.test(line)) { pendingDescription = ""; inTable = false; continue; }
    if (/^serial\s*(?:no\.?|number|#)\s*:/i.test(line)) {
      if (attachSerial && items.length) items[items.length - 1].description += `\n${line}`;
      continue;
    }
    attachSerial = false;
    const values = line.match(valuesRow);
    const complete = line.match(fullRow);
    const description = values ? pendingDescription : complete?.[1].replace(/^\d+[.)-]?\s+/, "").trim();
    const columns = values ? values.slice(1) : complete?.slice(2);
    if (description && columns) {
      const quantity = Number(columns[0]);
      const unitPrice = amount(columns[1]);
      const printedAmount = amount(columns[2]);
      if (quantity > 0 && unitPrice !== null && printedAmount !== null && Math.abs(Math.round(quantity * unitPrice * 100) / 100 - printedAmount) <= 0.01) {
        items.push({ description, quantity, unitPrice, amount: printedAmount });
        attachSerial = true;
        pendingDescription = "";
        continue;
      }
    }
    if (values || complete) pendingDescription = "";
    if (inTable && !values && !complete && !/^(?:#|quantity|qty|price|amount|page)\b/i.test(line)) pendingDescription = pendingDescription ? `${pendingDescription} ${line}` : line.replace(/^\d+[.)-]?\s+/, "");
  }
  return items;
}

export function extractBillFields(text: string): ExtractedBill {
  const lines = text.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const subtotal = labelledAmount(lines, /(?:sub\s*total|taxable\s*(?:amount|value))\s*[:=\-]?\s*(?:pkr|rs\.?|₨)?/i);
  let gst = labelledAmount(lines, /(?:gst|sales\s*tax|vat)\s*(?:@?\s*\d+(?:\.\d+)?\s*%)?\s*[:=\-]?\s*(?:pkr|rs\.?|₨)?/i);
  const total = labelledAmount(lines, /(?:^total|grand\s*total|invoice\s*total|amount\s*due|total\s*payable)\s*[:=\-]?\s*(?:pkr|rs\.?|₨)?/i, true);
  const labelledSupplier = lines.find((line) => /^(?:supplier|vendor|from)\s*:/i.test(line))?.replace(/^[^:]+:\s*/, "").trim() ?? "";
  const invoiceHeading = lines.findIndex((line) => /^invoice$/i.test(line));
  const supplier = labelledSupplier || (invoiceHeading > 0 ? lines[invoiceHeading - 1] : "");
  const reference = text.match(/(?:invoice|bill)\s*(?:no\.?|number|#)\s*[.:#-]?\s*([a-z\d/-]+)/i)?.[1] ?? "";
  const warnings: string[] = [];
  const items = extractItemRows(text);
  if (!items.length) warnings.push("No item rows could be matched reliably. Add each invoice item manually from the original document.");
  else if (subtotal !== null && Math.abs(items.reduce((sum, item) => sum + item.amount, 0) - subtotal) > 0.02)
    warnings.push("Detected item rows do not match the printed subtotal. Check for missing items, discounts or OCR errors.");
  if (!supplier) warnings.push("Supplier could not be identified. Choose the correct supplier.");
  if (!dateFrom(text)) warnings.push("Invoice date could not be verified. Check the date.");
  if (subtotal === null || total === null) warnings.push("Subtotal or grand total is missing. Enter amounts manually.");
  if (subtotal !== null && total !== null && Math.abs(subtotal + (gst ?? 0) - total) > 0.02)
    warnings.push("Extracted subtotal, GST and total do not balance. Correct them before saving.");
  if (gst === null) {
    warnings.push("GST was not printed separately. Confirm the tax treatment before posting.");
    if (subtotal !== null && total !== null && Math.abs(subtotal - total) <= 0.01) gst = 0;
  }
  return { text, supplier, invoiceDate: dateFrom(text), reference, subtotal, gst, total, items, warnings };
}

export function reviewedAmounts(subtotal: number, gst: number, total: number): { rate: number; error: string } {
  if (![subtotal, gst, total].every(Number.isFinite) || subtotal <= 0 || gst < 0 || total <= 0) return { rate: 0, error: "Enter positive subtotal and total, and non-negative GST." };
  if (Math.abs(subtotal + gst - total) > 0.02) return { rate: 0, error: "Subtotal + GST must equal the invoice total." };
  const rate = Math.round(gst / subtotal * 10000) / 100;
  if (rate > 100 || Math.abs(Math.round(subtotal * rate) / 100 - gst) > 0.02) return { rate: 0, error: "GST rate cannot reproduce this tax amount. Review the document and enter bill lines manually." };
  return { rate, error: "" };
}

export async function readDocument(file: File, nativePdfOnly = false): Promise<string> {
  if (file.size > 12 * 1024 * 1024) throw new Error("Maximum file size is 12 MB.");
  const extension = file.name.split(".").pop()?.toLowerCase();
  if (extension === "txt") return file.text();
  if (extension === "docx") {
    const mammoth = await import("mammoth/mammoth.browser");
    const result = await mammoth.extractRawText({ arrayBuffer: await file.arrayBuffer() });
    return result.value;
  }
  if (extension === "png" || extension === "jpg" || extension === "jpeg" || extension === "webp") {
    const { default: Tesseract } = await import("tesseract.js");
    const result = await Tesseract.recognize(file, "eng");
    return result.data.text;
  }
  if (extension === "pdf") {
    const pdfjs = await import("pdfjs-dist");
    pdfjs.GlobalWorkerOptions.workerSrc = new URL("pdfjs-dist/build/pdf.worker.min.mjs", import.meta.url).toString();
    const pdf = await pdfjs.getDocument({ data: await file.arrayBuffer() }).promise;
    if (pdf.numPages > 10) throw new Error("Maximum 10 pages per document.");
    const pages: string[] = [];
    for (let index = 1; index <= pdf.numPages; index++) {
      const page = await pdf.getPage(index);
      const content = await page.getTextContent();
      const rows: { y: number; parts: { x: number; value: string }[] }[] = [];
      for (const item of content.items) {
        if (!("str" in item) || !item.str.trim()) continue;
        const [x, y] = [item.transform[4], item.transform[5]];
        let row = rows.find((candidate) => Math.abs(candidate.y - y) <= 2);
        if (!row) { row = { y, parts: [] }; rows.push(row); }
        row.parts.push({ x, value: item.str });
      }
      const text = rows.sort((a, b) => b.y - a.y).map((row) => row.parts.sort((a, b) => a.x - b.x).map((part) => part.value).join(" ")).join("\n");
      if (text.trim().length > 25) pages.push(text);
      else {
        if (nativePdfOnly) return "";
        const viewport = page.getViewport({ scale: 2 });
        const canvas = document.createElement("canvas");
        canvas.width = viewport.width; canvas.height = viewport.height;
        const context = canvas.getContext("2d");
        if (!context) throw new Error("Canvas is unavailable for scanned PDF pages.");
        await page.render({ canvasContext: context, canvas, viewport }).promise;
        const { default: Tesseract } = await import("tesseract.js");
        pages.push((await Tesseract.recognize(canvas, "eng")).data.text);
      }
    }
    return pages.join("\n");
  }
  throw new Error("Supported formats: PDF, JPG, PNG, WebP, DOCX and TXT. Legacy DOC files must be converted to DOCX or PDF.");
}
