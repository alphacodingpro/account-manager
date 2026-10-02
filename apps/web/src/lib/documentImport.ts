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
};

export type ExtractedItem = { description: string; quantity: number; unitPrice: number; amount: number };

const amount = (value: string) => {
  const parsed = Number(value.replace(/[,\s]/g, ""));
  return Number.isFinite(parsed) && parsed >= 0 ? Math.round(parsed * 100) / 100 : null;
};

function labelledAmount(lines: string[], pattern: RegExp): number | null {
  for (const line of [...lines].reverse()) {
    const label = line.match(pattern);
    if (!label) continue;
    const tail = line.slice((label.index ?? 0) + label[0].length);
    const values = [...tail.matchAll(/\d[\d,]*(?:\.\d{1,2})?/g)].filter((match) => !/^\s*%/.test(tail.slice((match.index ?? 0) + match[0].length)));
    if (values.length) return amount(values[0][0]);
  }
  return null;
}

function dateFrom(text: string): string {
  const match = text.match(/(?:invoice|bill|issue)\s*date\s*[:#-]?\s*(\d{1,4}[./-]\d{1,2}[./-]\d{1,4})/i);
  if (!match) return "";
  const parts = match[1].split(/[./-]/).map(Number);
  const [year, month, day] = parts[0] > 1900 ? parts : [parts[2], parts[1], parts[0]];
  const valid = new Date(Date.UTC(year, month - 1, day));
  return valid.getUTCFullYear() === year && valid.getUTCMonth() === month - 1 && valid.getUTCDate() === day
    ? `${year}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}` : "";
}

// Deliberately conservative: OCR/PDF layouts vary. Only accept rows whose
// quantity × unit price reproduces the printed amount within one paisa.
export function extractItemRows(text: string): ExtractedItem[] {
  const items: ExtractedItem[] = [];
  const number = "(\\d[\\d,]*(?:\\.\\d{1,2})?)";
  const row = new RegExp(`^(.{3,}?)\\s+(\\d+(?:\\.\\d{1,3})?)\\s+(?:PKR|Rs\\.?|₨)?\\s*${number}\\s+(?:PKR|Rs\\.?|₨)?\\s*${number}$`, "i");
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.replace(/\s+/g, " ").trim();
    if (/\b(subtotal|grand total|invoice total|amount due|total payable|balance|discount|sales tax|gst|vat)\b/i.test(line)) continue;
    const match = line.match(row);
    if (!match) continue;
    const description = match[1].replace(/^(?:\d+[.)-]?\s+|item\s*\d+\s+)/i, "").trim();
    const quantity = Number(match[2]);
    const unitPrice = amount(match[3]);
    const printedAmount = amount(match[4]);
    if (!description || !Number.isFinite(quantity) || quantity <= 0 || unitPrice === null || printedAmount === null || Math.abs(Math.round(quantity * unitPrice * 100) / 100 - printedAmount) > 0.01) continue;
    items.push({ description, quantity, unitPrice, amount: printedAmount });
  }
  return items;
}

export function extractBillFields(text: string): ExtractedBill {
  const lines = text.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const subtotal = labelledAmount(lines, /(?:sub\s*total|taxable\s*(?:amount|value))\s*[:=\-]?\s*(?:pkr|rs\.?|₨)?/i);
  const gst = labelledAmount(lines, /(?:gst|sales\s*tax|vat)\s*(?:@?\s*\d+(?:\.\d+)?\s*%)?\s*[:=\-]?\s*(?:pkr|rs\.?|₨)?/i);
  const total = labelledAmount(lines, /(?:grand\s*total|invoice\s*total|amount\s*due|total\s*payable)\s*[:=\-]?\s*(?:pkr|rs\.?|₨)?/i);
  const supplier = lines.find((line) => /^(?:supplier|vendor|from)\s*:/i.test(line))?.replace(/^[^:]+:\s*/, "").trim() ?? "";
  const reference = text.match(/(?:invoice|bill)\s*(?:no\.?|number|#)\s*[:#-]?\s*([a-z\d/-]+)/i)?.[1] ?? "";
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
  if (gst === null) warnings.push("GST was not identified. Confirm whether the invoice includes GST.");
  return { text, supplier, invoiceDate: dateFrom(text), reference, subtotal, gst, total, items, warnings };
}

export function reviewedAmounts(subtotal: number, gst: number, total: number): { rate: number; error: string } {
  if (![subtotal, gst, total].every(Number.isFinite) || subtotal <= 0 || gst < 0 || total <= 0) return { rate: 0, error: "Enter positive subtotal and total, and non-negative GST." };
  if (Math.abs(subtotal + gst - total) > 0.02) return { rate: 0, error: "Subtotal + GST must equal the invoice total." };
  const rate = Math.round(gst / subtotal * 10000) / 100;
  if (rate > 100 || Math.abs(Math.round(subtotal * rate) / 100 - gst) > 0.02) return { rate: 0, error: "GST rate cannot reproduce this tax amount. Review the document and enter bill lines manually." };
  return { rate, error: "" };
}

export async function readDocument(file: File): Promise<string> {
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
