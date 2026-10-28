import { useEffect, useMemo, useRef, useState } from "react";
import { CornerDownLeft, Search } from "lucide-react";

export type FinderPage = { label: string; hint: string; keywords?: string; run: () => void };

/** Type a few letters ("inv", "gst", "bank") and jump straight to that page. Ctrl/Cmd+K focuses it. */
export default function PageFinder({ pages }: { pages: FinderPage[] }) {
  const [query, setQuery] = useState("");
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const input = useRef<HTMLInputElement>(null);
  const box = useRef<HTMLDivElement>(null);

  const results = useMemo(() => {
    const words = query.toLowerCase().split(/\s+/).filter(Boolean);
    const scored = pages.map((page) => {
      const text = `${page.label} ${page.hint} ${page.keywords ?? ""}`.toLowerCase();
      if (!words.every((w) => text.includes(w))) return null;
      const label = page.label.toLowerCase();
      const score = words.length ? (label.startsWith(words[0]) ? 0 : label.includes(words[0]) ? 1 : 2) : 0;
      return { page, score };
    }).filter((x): x is { page: FinderPage; score: number } => !!x);
    return scored.sort((a, b) => a.score - b.score).slice(0, 8).map((x) => x.page);
  }, [pages, query]);

  useEffect(() => { setActive(0); }, [query]);
  useEffect(() => {
    const shortcut = (event: KeyboardEvent) => { if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") { event.preventDefault(); input.current?.focus(); input.current?.select(); setOpen(true); } };
    const outside = (event: PointerEvent) => { if (!box.current?.contains(event.target as Node)) setOpen(false); };
    document.addEventListener("keydown", shortcut);
    document.addEventListener("pointerdown", outside);
    return () => { document.removeEventListener("keydown", shortcut); document.removeEventListener("pointerdown", outside); };
  }, []);

  function choose(page?: FinderPage) {
    if (!page) return;
    page.run(); setQuery(""); setOpen(false); input.current?.blur();
  }

  return (
    <div className="search page-finder" ref={box}>
      <Search />
      <input ref={input} value={query} role="combobox" aria-expanded={open} aria-controls="page-finder-list" aria-label="Go to a page" placeholder="Go to a page: invoices, bills, reports..." autoComplete="off"
        onFocus={() => setOpen(true)} onChange={(e) => { setQuery(e.target.value); setOpen(true); }}
        onKeyDown={(e) => {
          if (e.key === "ArrowDown") { e.preventDefault(); setActive((i) => Math.min(i + 1, results.length - 1)); }
          else if (e.key === "ArrowUp") { e.preventDefault(); setActive((i) => Math.max(i - 1, 0)); }
          else if (e.key === "Enter") { e.preventDefault(); choose(results[active]); }
          else if (e.key === "Escape") { setOpen(false); input.current?.blur(); }
        }} />
      <kbd>⌘ K</kbd>
      {open && <ul id="page-finder-list" role="listbox" className="finder-list">
        {results.length === 0 && <li className="finder-empty">No page matches "{query}".</li>}
        {results.map((page, i) => <li key={`${page.hint}-${page.label}`} role="option" aria-selected={i === active} className={i === active ? "active" : ""} onMouseEnter={() => setActive(i)} onMouseDown={(e) => { e.preventDefault(); choose(page); }}>
          <span><b>{page.label}</b>{page.hint && <small>{page.hint}</small>}</span>{i === active && <CornerDownLeft size={14} />}
        </li>)}
      </ul>}
    </div>
  );
}
