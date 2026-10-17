import { useEffect, useRef, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { X } from "lucide-react";

/**
 * One popup used for every entry, edit, confirmation and detail view so that
 * all pages behave and look the same.
 *
 * - Closes with the X button, the Escape key or (for read-only views) a click on the backdrop.
 *   Entry forms do NOT close on backdrop click, so a stray click never loses typed data.
 * - Locks page scrolling, keeps keyboard focus inside, focuses the first field, and
 *   returns focus to the button that opened it.
 * - Shows save errors inside the popup, so they are never hidden behind the overlay.
 * - Becomes a full-screen sheet on phones.
 */
export type ModalSize = "sm" | "md" | "lg" | "xl";

type ModalProps = {
  /** Defaults to true: callers keep their own `{cond && <Modal>}` guard so children are only built when needed. */
  open?: boolean;
  onClose: () => void;
  title: ReactNode;
  subtitle?: ReactNode;
  size?: ModalSize;
  /** Text to show at the top of the popup (errors or success). */
  message?: string;
  /** Close when the dark backdrop is clicked. Use for read-only details only. */
  closeOnBackdrop?: boolean;
  children: ReactNode;
};

const openStack: symbol[] = [];
let lockCount = 0;

function lockScroll() {
  if (lockCount++ === 0) document.body.style.overflow = "hidden";
}
function unlockScroll() {
  if (--lockCount <= 0) { lockCount = 0; document.body.style.overflow = ""; }
}

const FOCUSABLE = 'input:not([type="hidden"]):not([disabled]):not([readonly]), select:not([disabled]), textarea:not([disabled]), button:not([disabled]), [href], [tabindex]:not([tabindex="-1"])';
const FIELDS = 'input:not([type="hidden"]):not([disabled]):not([readonly]):not([type="checkbox"]), select:not([disabled]), textarea:not([disabled])';

const SUCCESS = /(success|saved|posted|created|approved|deleted|converted|recorded|submitted)/i;

export default function Modal({ open = true, onClose, title, subtitle, size = "md", message, closeOnBackdrop = false, children }: ModalProps) {
  const dialogRef = useRef<HTMLDivElement>(null);
  const bodyRef = useRef<HTMLDivElement>(null);
  const closeRef = useRef(onClose);
  closeRef.current = onClose;

  useEffect(() => {
    if (!open) return;
    const id = Symbol("modal");
    openStack.push(id);
    lockScroll();
    const previous = document.activeElement as HTMLElement | null;
    const timer = window.setTimeout(() => {
      const first = bodyRef.current?.querySelector<HTMLElement>(FIELDS);
      (first ?? dialogRef.current)?.focus();
    }, 30);

    function onKey(event: KeyboardEvent) {
      if (openStack[openStack.length - 1] !== id) return;
      if (event.key === "Escape") { event.stopPropagation(); closeRef.current(); return; }
      if (event.key !== "Tab" || !dialogRef.current) return;
      const items = Array.from(dialogRef.current.querySelectorAll<HTMLElement>(FOCUSABLE)).filter((el) => el.offsetParent !== null);
      if (!items.length) return;
      const first = items[0], last = items[items.length - 1];
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    }
    document.addEventListener("keydown", onKey, true);
    return () => {
      window.clearTimeout(timer);
      document.removeEventListener("keydown", onKey, true);
      const at = openStack.indexOf(id);
      if (at >= 0) openStack.splice(at, 1);
      unlockScroll();
      previous?.focus?.();
    };
  }, [open]);

  if (!open) return null;

  return createPortal(
    <div
      className="modal-backdrop"
      onMouseDown={(event) => { if (closeOnBackdrop && event.target === event.currentTarget) onClose(); }}
    >
      <div ref={dialogRef} className={`modal modal-${size}`} role="dialog" aria-modal="true" aria-label={typeof title === "string" ? title : undefined} tabIndex={-1}>
        <header className="modal-head">
          <div>
            <h2>{title}</h2>
            {subtitle && <p>{subtitle}</p>}
          </div>
          <button type="button" className="modal-close" onClick={onClose} aria-label="Close"><X size={18} /></button>
        </header>
        <div className="modal-body" ref={bodyRef}>
          {message ? <p className={SUCCESS.test(message) ? "notice" : "alert"} role="alert">{message}</p> : null}
          {children}
        </div>
      </div>
    </div>,
    document.body,
  );
}

/** Colour-coded status pill so "posted", "draft" and "void" never look the same. */
export function statusClass(value: unknown): string {
  const s = String(value ?? "").toLowerCase();
  if (/^(posted|paid|active|approved|received|present|reconciled|complete|completed|delivered|confirmed)/.test(s)) return "status s-ok";
  if (/^(draft|pending|partial|open|sent|submitted|unmatched)/.test(s)) return "status s-warn";
  if (/^(void|reversed|inactive|rejected|cancel|absent|overdue|expired|deleted)/.test(s)) return "status s-bad";
  return "status s-info";
}
