import { useState } from "react";
import { FileDown } from "lucide-react";
import { exportPdf, type PdfSpec } from "./lib/pdfExport";

/** Downloads a professional PDF. `build` may fetch data first, so it can be async. */
export default function PdfButton({ build, label = "PDF", className = "outline small-button", disabled, title }: { build: () => PdfSpec | Promise<PdfSpec>; label?: string; className?: string; disabled?: boolean; title?: string }) {
  const [busy, setBusy] = useState(false);
  async function run() {
    setBusy(true);
    try { await exportPdf(await build()); }
    catch (error) { window.alert(`The PDF could not be created: ${error instanceof Error ? error.message : String(error)}`); }
    finally { setBusy(false); }
  }
  return <button type="button" className={className} disabled={disabled || busy} title={title ?? "Download as a professional PDF"} onClick={() => void run()}><FileDown size={15} /> {busy ? "Preparing…" : label}</button>;
}
