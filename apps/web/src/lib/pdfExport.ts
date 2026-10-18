/**
 * One professional PDF layout for every document and report in CloudLedger PK.
 *
 *  - Letterhead: logo, company name, legal name, address, phone/email/web, NTN/STRN
 *  - Document block: title, number, date, status
 *  - Party / detail boxes, a styled table, totals, amount in words, notes, signatures
 *  - Running header on later pages, footer with generated date and "Page x of y"
 *  - "DRAFT" / "VOID" watermark for documents that are not final
 *
 * jsPDF is loaded on demand so it never slows down the normal app start.
 */
import type { jsPDF as JsPdf } from "jspdf";

export type PdfCompany = {
  name: string;
  legal_name?: string | null;
  ntn?: string | null;
  strn?: string | null;
  gst_registered?: boolean | null;
  address?: string | null;
  phone?: string | null;
  email?: string | null;
  website?: string | null;
  logo_data_url?: string | null;
};

export type PdfColumn = { header: string; align?: "left" | "right" | "center"; width?: number };
export type PdfCell = string | number | null | undefined;

export type PdfSpec = {
  /** Defaults to the active company (set once by the app with setPdfCompany). */
  company?: PdfCompany;
  /** Document or report title, e.g. "Sales Invoice" or "Trial Balance". */
  title: string;
  number?: string;
  date?: string;
  status?: string;
  /** Shown under the title, e.g. the report period. */
  subtitle?: string;
  /** Bill to / Supplier / Employee boxes. */
  parties?: { label: string; lines: (string | null | undefined)[] }[];
  /** Key / value facts such as due date, reference, branch. */
  meta?: [string, string | null | undefined][];
  columns: PdfColumn[];
  rows: PdfCell[][];
  /** Lines under the table; `grand` is drawn as a coloured band. */
  totals?: [string, string, ("bold" | "grand")?][];
  /** Adds "Amount in words" under the totals. */
  amountInWords?: number;
  notes?: string;
  signatures?: string[];
  filename: string;
  orientation?: "portrait" | "landscape";
  /** Shown in the footer, e.g. "Posted double-entry data only". */
  footnote?: string;
};

const NAVY: [number, number, number] = [18, 50, 77];
const BLUE: [number, number, number] = [22, 119, 255];
const INK: [number, number, number] = [33, 52, 68];
const MUTED: [number, number, number] = [109, 130, 148];
const LINE: [number, number, number] = [221, 229, 236];
const ZEBRA: [number, number, number] = [247, 250, 252];

let activeCompany: PdfCompany | null = null;
/** Called by the app whenever the active company (or its letterhead) changes. */
export function setPdfCompany(company: PdfCompany | null) { activeCompany = company; }
export function getPdfCompany() { return activeCompany; }

/* ---------- formatting helpers ---------- */
const REPLACE: Record<string, string> = { "\u2018": "'", "\u2019": "'", "\u201c": '"', "\u201d": '"', "\u2013": "-", "\u2014": "-", "\u2026": "...", "\u2022": "-", "\u20a8": "Rs", "\u00a0": " ", "\u2192": "->" };
/** The built-in PDF fonts only cover Latin text; anything else becomes "?" instead of garbage. */
export const pdfSafe = (value: unknown) => String(value ?? "")
  .replace(/[\u2018\u2019\u201c\u201d\u2013\u2014\u2026\u2022\u20a8\u00a0\u2192]/g, (c) => REPLACE[c])
  .replace(/[^\n\x20-\x7E\u00A1-\u00FF]/g, "?");

export const pdfMoney = (value: unknown) => {
  const n = Number(value ?? 0);
  if (!Number.isFinite(n)) return pdfSafe(value);
  return `${n < 0 ? "-" : ""}PKR ${Math.abs(n).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
};
export const pdfNumber = (value: unknown, digits = 2) => {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? n.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits }) : pdfSafe(value);
};
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
export const pdfDate = (value?: string | Date | null) => {
  if (!value) return "";
  const text = typeof value === "string" ? value : value.toISOString();
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(text);
  if (!m) return pdfSafe(text);
  return `${Number(m[3])} ${MONTHS[Number(m[2]) - 1] ?? m[2]} ${m[1]}`;
};
export const pdfPeriod = (from?: string, to?: string) => from && to ? `${pdfDate(from)} to ${pdfDate(to)}` : from ? `From ${pdfDate(from)}` : to ? `As of ${pdfDate(to)}` : "";

const ONES = ["", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Eleven", "Twelve", "Thirteen", "Fourteen", "Fifteen", "Sixteen", "Seventeen", "Eighteen", "Nineteen"];
const TENS = ["", "", "Twenty", "Thirty", "Forty", "Fifty", "Sixty", "Seventy", "Eighty", "Ninety"];
const below100 = (n: number) => n < 20 ? ONES[n] : `${TENS[Math.floor(n / 10)]}${n % 10 ? ` ${ONES[n % 10]}` : ""}`;
const below1000 = (n: number) => `${n >= 100 ? `${ONES[Math.floor(n / 100)]} Hundred${n % 100 ? " " : ""}` : ""}${n % 100 ? below100(n % 100) : ""}`;
/** Pakistani numbering: thousand, lakh, crore, arab. */
export function rupeesInWords(amount: number): string {
  const abs = Math.abs(Number(amount) || 0);
  let rupees = Math.floor(abs);
  let paisa = Math.round((abs - rupees) * 100);
  if (paisa === 100) { rupees += 1; paisa = 0; }
  const units: [number, string][] = [[1e9, "Arab"], [1e7, "Crore"], [1e5, "Lakh"], [1e3, "Thousand"]];
  const parts: string[] = [];
  let rest = rupees;
  for (const [size, name] of units) {
    const count = Math.floor(rest / size);
    if (count > 0) { parts.push(`${below1000(count)} ${name}`); rest -= count * size; }
  }
  if (rest > 0) parts.push(below1000(rest));
  const words = parts.length ? parts.join(" ") : "Zero";
  return `${amount < 0 ? "Minus " : ""}${words} Rupees${paisa ? ` and ${below100(paisa)} Paisa` : ""} Only`;
}

/* ---------- drawing ---------- */
type Doc = JsPdf & { lastAutoTable?: { finalY: number }; GState?: new (o: { opacity: number }) => unknown };

function wrap(doc: Doc, text: string, width: number): string[] {
  return doc.splitTextToSize(pdfSafe(text), width) as string[];
}

function statusColour(status: string): [number, number, number] {
  if (/draft|pending/i.test(status)) return [191, 120, 0];
  if (/void|reversed|cancel|reject/i.test(status)) return [179, 38, 30];
  return [14, 140, 98];
}

function drawLetterhead(doc: Doc, spec: PdfSpec, company: PdfCompany, margin: number, pageW: number): number {
  const right = pageW - margin;
  let x = margin;
  let top = 13;
  let leftBottom = top;
  if (company.logo_data_url) {
    try {
      const props = doc.getImageProperties(company.logo_data_url);
      const maxW = 38, maxH = 17;
      const scale = Math.min(maxW / props.width, maxH / props.height);
      const w = props.width * scale, h = props.height * scale;
      doc.addImage(company.logo_data_url, props.fileType, margin, top - 1, w, h);
      x = margin + w + 5;
      leftBottom = top - 1 + h;
    } catch { /* an unreadable logo must never block the export */ }
  }
  const textWidth = Math.min(100, right - x - 70);
  let y = top + 4;
  doc.setFont("helvetica", "bold").setFontSize(15).setTextColor(...NAVY);
  for (const line of wrap(doc, company.name, textWidth)) { doc.text(line, x, y); y += 6; }
  doc.setFont("helvetica", "normal").setFontSize(8.2).setTextColor(...MUTED);
  const detail: string[] = [];
  if (company.legal_name && company.legal_name.trim() && company.legal_name.trim() !== company.name.trim()) detail.push(company.legal_name);
  if (company.address) detail.push(...company.address.split(/\n+/));
  // Contact and tax details flow onto lines without leaving a separator at the end of a line.
  const flow = (items: (string | null | undefined | false)[]) => {
    let current = "";
    for (const item of items) {
      if (!item) continue;
      const next = current ? `${current}   |   ${item}` : item;
      if (current && doc.getTextWidth(pdfSafe(next)) > textWidth) { detail.push(current); current = item; } else current = next;
    }
    if (current) detail.push(current);
  };
  flow([company.phone && `Tel: ${company.phone}`, company.email, company.website]);
  flow([company.ntn && `NTN: ${company.ntn}`, company.strn && `STRN: ${company.strn}`]);
  for (const entry of detail) for (const line of wrap(doc, entry, textWidth)) { doc.text(line, x, y); y += 3.9; }
  leftBottom = Math.max(leftBottom, y);

  // right: document title block
  let ry = top + 5;
  doc.setFont("helvetica", "bold").setFontSize(19).setTextColor(...BLUE);
  doc.text(pdfSafe(spec.title).toUpperCase(), right, ry, { align: "right" });
  doc.setTextColor(...INK);
  if (spec.number) { ry += 6.5; doc.setFontSize(11); doc.text(pdfSafe(spec.number), right, ry, { align: "right" }); }
  doc.setFont("helvetica", "normal").setFontSize(9).setTextColor(...INK);
  if (spec.date) { ry += 5.2; doc.text(`Date: ${pdfDate(spec.date)}`, right, ry, { align: "right" }); }
  if (spec.subtitle) { ry += 5.2; doc.setTextColor(...MUTED); for (const line of wrap(doc, spec.subtitle, 80)) { doc.text(line, right, ry, { align: "right" }); ry += 4.4; } ry -= 4.4; }
  if (spec.status) {
    ry += 8;
    const label = pdfSafe(spec.status).toUpperCase();
    doc.setFont("helvetica", "bold").setFontSize(8);
    const w = doc.getTextWidth(label) + 7;
    const colour = statusColour(spec.status);
    doc.setDrawColor(...colour).setLineWidth(0.4).roundedRect(right - w, ry - 3.6, w, 6, 1.6, 1.6, "S");
    doc.setTextColor(...colour).text(label, right - w / 2, ry + 0.6, { align: "center" });
    ry += 4;
  }
  const bottom = Math.max(leftBottom, ry) + 3;
  doc.setDrawColor(...BLUE).setLineWidth(0.7).line(margin, bottom, right, bottom);
  return bottom + 5;
}

function drawBoxes(doc: Doc, spec: PdfSpec, margin: number, pageW: number, y: number): number {
  const boxes: { label: string; lines: string[] }[] = [];
  for (const party of spec.parties ?? []) {
    const lines = party.lines.filter((l): l is string => !!l && !!l.trim());
    if (lines.length) boxes.push({ label: party.label, lines });
  }
  const meta = (spec.meta ?? []).filter(([, v]) => v !== undefined && v !== null && String(v).trim() !== "");
  if (!boxes.length && !meta.length) return y;
  const total = pageW - margin * 2;
  const count = boxes.length + (meta.length ? 1 : 0);
  const gap = 6;
  const w = (total - gap * (count - 1)) / count;
  let x = margin;
  let maxBottom = y;
  const drawFrame = (height: number) => { doc.setFillColor(...ZEBRA).setDrawColor(...LINE).setLineWidth(0.2).roundedRect(x, y, w, height, 1.8, 1.8, "FD"); };
  const prepared = [
    ...boxes.map((b) => ({ label: b.label, rows: b.lines.flatMap((l, i) => wrap(doc, l, w - 8).map((t) => ({ k: "", v: t, bold: i === 0 }))) })),
    ...(meta.length ? [{ label: "Details", rows: meta.map(([k, v]) => ({ k: pdfSafe(k), v: pdfSafe(v), bold: false })) }] : []),
  ];
  const height = Math.max(...prepared.map((b) => 9 + b.rows.length * 4.6)) + 1;
  for (const box of prepared) {
    drawFrame(height);
    doc.setFont("helvetica", "bold").setFontSize(7.2).setTextColor(...MUTED).text(pdfSafe(box.label).toUpperCase(), x + 4, y + 5);
    let ty = y + 10;
    for (const row of box.rows) {
      if (row.k) {
        doc.setFont("helvetica", "normal").setFontSize(8.6).setTextColor(...MUTED).text(row.k, x + 4, ty);
        doc.setFont("helvetica", "bold").setTextColor(...INK).text(row.v, x + w - 4, ty, { align: "right" });
      } else {
        doc.setFont("helvetica", row.bold ? "bold" : "normal").setFontSize(row.bold ? 10 : 8.8).setTextColor(...INK).text(row.v, x + 4, ty);
      }
      ty += 4.6;
    }
    maxBottom = Math.max(maxBottom, y + height);
    x += w + gap;
  }
  return maxBottom + 6;
}

function drawTotals(doc: Doc, spec: PdfSpec, margin: number, pageW: number, pageH: number, y: number): number {
  const totals = spec.totals ?? [];
  if (!totals.length && !spec.amountInWords) return y;
  const boxW = 86;
  const right = pageW - margin;
  const needed = totals.length * 7 + (spec.amountInWords !== undefined ? 16 : 0) + 6;
  if (y + needed > pageH - 22) { doc.addPage(); y = 24; }
  const x = right - boxW;
  for (const [label, value, kind] of totals) {
    if (kind === "grand") {
      doc.setFillColor(...NAVY).roundedRect(x, y - 4.6, boxW, 8.2, 1.6, 1.6, "F");
      doc.setFont("helvetica", "bold").setFontSize(10).setTextColor(255, 255, 255);
      doc.text(pdfSafe(label), x + 3.5, y + 0.9);
      doc.text(pdfSafe(value), right - 3.5, y + 0.9, { align: "right" });
      y += 9.6;
    } else {
      doc.setFont("helvetica", kind === "bold" ? "bold" : "normal").setFontSize(9).setTextColor(...INK);
      doc.text(pdfSafe(label), x + 3.5, y);
      doc.text(pdfSafe(value), right - 3.5, y, { align: "right" });
      doc.setDrawColor(...LINE).setLineWidth(0.15).line(x, y + 2, right, y + 2);
      y += 6.4;
    }
  }
  if (spec.amountInWords !== undefined) {
    y += 2;
    const words = `${rupeesInWords(spec.amountInWords)}`;
    doc.setFont("helvetica", "bold").setFontSize(7.4).setTextColor(...MUTED).text("AMOUNT IN WORDS", margin, y);
    doc.setFont("helvetica", "italic").setFontSize(9).setTextColor(...INK);
    const lines = wrap(doc, words, pageW - margin * 2 - boxW - 8);
    doc.text(lines, margin, y + 4.6);
    y += Math.max(6, 4.6 * lines.length + 3);
  }
  return y + 4;
}

export async function buildPdf(spec: PdfSpec): Promise<JsPdf> {
  const company = spec.company ?? activeCompany ?? { name: "CloudLedger PK" };
  const [{ jsPDF }, autoTableModule] = await Promise.all([import("jspdf"), import("jspdf-autotable")]);
  const autoTable = autoTableModule.default;
  const landscape = spec.orientation === "landscape";
  const doc = new jsPDF({ orientation: landscape ? "landscape" : "portrait", unit: "mm", format: "a4", compress: true }) as Doc;
  const pageW = doc.internal.pageSize.getWidth();
  const pageH = doc.internal.pageSize.getHeight();
  const margin = 14;
  const generated = new Date();
  const stamp = `${pdfDate(generated.toISOString())} ${generated.toTimeString().slice(0, 5)}`;
  doc.setProperties({ title: pdfSafe(`${spec.title}${spec.number ? ` ${spec.number}` : ""}`), author: pdfSafe(company.name), creator: "CloudLedger PK", subject: pdfSafe(spec.subtitle ?? spec.title) });

  let y = drawLetterhead(doc, spec, company, margin, pageW);
  y = drawBoxes(doc, spec, margin, pageW, y);

  const columnStyles: Record<number, { halign: "left" | "right" | "center"; cellWidth?: number }> = {};
  spec.columns.forEach((c, i) => { columnStyles[i] = { halign: c.align ?? "left", ...(c.width ? { cellWidth: c.width } : {}) }; });
  const body = spec.rows.map((row) => row.map((cell) => pdfSafe(cell)));
  const slimHeader = () => {
    doc.setFont("helvetica", "bold").setFontSize(8.5).setTextColor(...NAVY).text(pdfSafe(company.name), margin, 11);
    doc.setFont("helvetica", "normal").setTextColor(...MUTED).text(pdfSafe(`${spec.title}${spec.number ? ` ${spec.number}` : ""}`), pageW - margin, 11, { align: "right" });
    doc.setDrawColor(...LINE).setLineWidth(0.3).line(margin, 13.5, pageW - margin, 13.5);
  };
  autoTable(doc, {
    startY: y,
    head: [spec.columns.map((c) => pdfSafe(c.header))],
    body,
    theme: "plain",
    margin: { top: 20, left: margin, right: margin, bottom: 20 },
    showHead: "everyPage",
    styles: { font: "helvetica", fontSize: 8.6, cellPadding: { top: 2.4, bottom: 2.4, left: 2.6, right: 2.6 }, textColor: INK, lineColor: LINE, lineWidth: { bottom: 0.15 }, overflow: "linebreak", valign: "middle" },
    headStyles: { fillColor: NAVY, textColor: [255, 255, 255], fontStyle: "bold", fontSize: 8, lineWidth: 0 },
    alternateRowStyles: { fillColor: ZEBRA },
    columnStyles,
    didParseCell: (data) => {
      if (data.section === "head") data.cell.styles.halign = columnStyles[data.column.index]?.halign ?? "left";
      if (data.section === "body") {
        const raw = (data.row.raw ?? []) as string[];
        if ([raw[0], raw[1]].some((cell) => /^(grand )?total\b|^net\b/i.test(String(cell ?? "").trim()))) { data.cell.styles.fontStyle = "bold"; data.cell.styles.fillColor = [236, 243, 250]; }
      }
    },
    didDrawPage: (data) => { if (data.pageNumber > 1) slimHeader(); },
  });
  if (!body.length) {
    doc.setFont("helvetica", "italic").setFontSize(9).setTextColor(...MUTED).text("No records for this selection.", margin, (doc.lastAutoTable?.finalY ?? y) + 8);
  }
  y = (doc.lastAutoTable?.finalY ?? y) + 8;
  y = drawTotals(doc, spec, margin, pageW, pageH, y);

  if (spec.notes && spec.notes.trim()) {
    const lines = wrap(doc, spec.notes, pageW - margin * 2);
    if (y + 10 + lines.length * 4.2 > pageH - 22) { doc.addPage(); y = 24; }
    doc.setFont("helvetica", "bold").setFontSize(7.4).setTextColor(...MUTED).text("NOTES", margin, y);
    doc.setFont("helvetica", "normal").setFontSize(8.8).setTextColor(...INK).text(lines, margin, y + 4.6);
    y += 8 + lines.length * 4.2;
  }
  if (spec.signatures?.length) {
    if (y + 28 > pageH - 18) { doc.addPage(); y = 30; }
    const slot = (pageW - margin * 2) / spec.signatures.length;
    const sy = Math.max(y + 18, pageH - 46);
    const lineY = Math.min(sy, pageH - 30);
    spec.signatures.forEach((label, i) => {
      const x0 = margin + i * slot;
      doc.setDrawColor(...MUTED).setLineWidth(0.25).line(x0 + 2, lineY, x0 + slot - 12, lineY);
      doc.setFont("helvetica", "normal").setFontSize(8).setTextColor(...MUTED).text(pdfSafe(label), x0 + 2, lineY + 4.5);
    });
  }

  // watermark + footer on every page
  const pages = doc.getNumberOfPages();
  const watermark = spec.status && /draft|void|reversed|cancel/i.test(spec.status) ? pdfSafe(spec.status).toUpperCase() : "";
  for (let p = 1; p <= pages; p++) {
    doc.setPage(p);
    if (watermark && doc.GState) {
      doc.saveGraphicsState();
      doc.setGState(new doc.GState({ opacity: 0.07 }) as never);
      doc.setFont("helvetica", "bold").setFontSize(landscape ? 96 : 84).setTextColor(...(statusColour(watermark)));
      doc.text(watermark, pageW / 2, pageH / 2 + 10, { align: "center", angle: landscape ? 20 : 45 });
      doc.restoreGraphicsState();
    }
    doc.setDrawColor(...LINE).setLineWidth(0.25).line(margin, pageH - 13, pageW - margin, pageH - 13);
    doc.setFont("helvetica", "normal").setFontSize(7.4).setTextColor(...MUTED);
    const left = [pdfSafe(company.name), spec.footnote && pdfSafe(spec.footnote), `Generated ${stamp} by CloudLedger PK`].filter(Boolean).join("   |   ");
    doc.text(left, margin, pageH - 8.5);
    doc.text(`Page ${p} of ${pages}`, pageW - margin, pageH - 8.5, { align: "right" });
  }
  return doc;
}

const fileSafe = (name: string) => name.replace(/[^A-Za-z0-9._-]+/g, "_").replace(/^_+|_+$/g, "") || "document";

/** Builds the PDF and downloads it. */
export async function exportPdf(spec: PdfSpec): Promise<void> {
  const doc = await buildPdf(spec);
  doc.save(`${fileSafe(spec.filename)}.pdf`);
}
