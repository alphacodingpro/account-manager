import { Children, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { MoreHorizontal } from "lucide-react";

/**
 * Action buttons for one table row.
 * The first action (normally View) stays visible; every other action moves into a "..." menu.
 * The row therefore stays the same small width in every table and can never push buttons off screen.
 * The menu is positioned on screen (not inside the table), so a scrolling table never clips it.
 * All actions stay mounted, so dialogs and downloads started from the menu keep working after it closes.
 */
export default function RowActions({ children }: { children?: ReactNode }) {
  const items = Children.toArray(children);
  const [first, ...rest] = items;
  const [open, setOpen] = useState(false);
  const [pos, setPos] = useState<{ top: number; right: number } | null>(null);
  const toggle = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement>(null);

  useLayoutEffect(() => {
    if (!open || !toggle.current || !menu.current) return;
    const anchor = toggle.current.getBoundingClientRect();
    const height = menu.current.offsetHeight;
    const below = window.innerHeight - anchor.bottom;
    const top = below >= height + 12 || anchor.top < height + 12 ? anchor.bottom + 6 : anchor.top - height - 6;
    setPos({ top: Math.max(8, Math.min(top, window.innerHeight - height - 8)), right: Math.max(8, window.innerWidth - anchor.right) });
    // Label buttons that only show an icon, using their tooltip text.
    menu.current.querySelectorAll("button").forEach((button) => {
      if (!button.textContent?.trim()) button.setAttribute("data-icon-only", "true");
    });
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const close = () => { setOpen(false); setPos(null); };
    const outside = (event: PointerEvent) => {
      const target = event.target as Node;
      if (menu.current?.contains(target) || toggle.current?.contains(target)) return;
      close();
    };
    const key = (event: KeyboardEvent) => { if (event.key === "Escape") { close(); toggle.current?.focus(); } };
    document.addEventListener("pointerdown", outside, true);
    document.addEventListener("keydown", key);
    window.addEventListener("resize", close);
    window.addEventListener("scroll", close, true);
    return () => {
      document.removeEventListener("pointerdown", outside, true);
      document.removeEventListener("keydown", key);
      window.removeEventListener("resize", close);
      window.removeEventListener("scroll", close, true);
    };
  }, [open]);

  if (!rest.length) return <span className="row-actions">{first}</span>;
  return (
    <span className="row-actions">
      {first}
      <button ref={toggle} type="button" className="row-more" aria-label="More actions" aria-haspopup="menu" aria-expanded={open} title="More actions"
        onClick={() => { if (open) { setOpen(false); setPos(null); } else setOpen(true); }}>
        <MoreHorizontal size={16} />
      </button>
      {createPortal(
      <div ref={menu} role="menu" className={`row-menu${open && pos ? " open" : ""}`} style={open && pos ? { top: pos.top, right: pos.right } : undefined}
        onClick={(event) => { if ((event.target as HTMLElement).closest("button")) window.setTimeout(() => { setOpen(false); setPos(null); }, 0); }}>
        {rest}
      </div>,
        document.body,
      )}
    </span>
  );
}
