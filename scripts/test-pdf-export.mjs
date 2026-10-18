import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build } from "esbuild";

const dir = mkdtempSync(join(tmpdir(), "pdf-"));
const out = join(dir, "pdf.mjs");
await build({ entryPoints: ["apps/web/src/lib/pdfExport.ts"], bundle: true, format: "esm", platform: "node", outfile: out, logLevel: "error", external: ["canvg", "html2canvas", "dompurify"] });
const { buildPdf, rupeesInWords, pdfDate, pdfMoney, pdfSafe, setPdfCompany } = await import(out);

assert.equal(rupeesInWords(0), "Zero Rupees Only");
assert.equal(rupeesInWords(100000), "One Lakh Rupees Only");
assert.equal(rupeesInWords(74800.5), "Seventy Four Thousand Eight Hundred Rupees and Fifty Paisa Only");
assert.equal(rupeesInWords(12345678.9), "One Crore Twenty Three Lakh Forty Five Thousand Six Hundred Seventy Eight Rupees and Ninety Paisa Only");
assert.equal(rupeesInWords(0.999), "One Rupees Only");
assert.equal(pdfDate("2026-10-17"), "17 Oct 2026");
assert.equal(pdfMoney(-1234.5), "-PKR 1,234.50");
assert.equal(pdfSafe("Ali \u2013 \u2018Co\u2019 \u0627\u0631\u062f\u0648"), "Ali - 'Co' ????");

setPdfCompany({ name: "UltraNet Security", ntn: "1234567-8", address: "Karachi" });
const spec = (rows, extra = {}) => ({ title: "Sales Invoice", number: "INV-000001", date: "2026-10-17", status: "draft", columns: [{ header: "Item" }, { header: "Total", align: "right" }], rows, totals: [["Total", "PKR 1.00", "grand"]], filename: "x", ...extra });
const small = await buildPdf(spec([["Camera", "1.00"]]));
assert.equal(small.getNumberOfPages(), 1);
const bytes = Buffer.from(small.output("arraybuffer"));
assert.equal(bytes.subarray(0, 5).toString(), "%PDF-");
assert.ok(bytes.length > 1500);
const long = await buildPdf(spec(Array.from({ length: 120 }, (_, i) => [`Item ${i}`, "1.00"])));
assert.ok(long.getNumberOfPages() >= 3, "long tables paginate");
const empty = await buildPdf(spec([], { totals: undefined, status: undefined }));
assert.equal(empty.getNumberOfPages(), 1);
const unreadableLogo = await buildPdf({ ...spec([["a", "1"]]), company: { name: "Bad Logo Co", logo_data_url: "data:image/png;base64,AAAA" } });
assert.equal(unreadableLogo.getNumberOfPages(), 1, "an unreadable logo never blocks the export");
console.log("PDF export checks passed.");
