import { useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { ArrowLeft, ArrowRight, X } from "lucide-react";

/**
 * A guided tour for new users: a spotlight on the real screen element plus a short explanation card.
 * Steps can navigate first (`before`), and a missing element (for example on a phone) simply shows
 * the card in the middle of the screen, so the tour never gets stuck.
 */
export type TourStep = {
  id: string;
  title: string;
  body: ReactNode;
  /** CSS selector of the element to highlight. Omit for a centred card. */
  target?: string;
  placement?: "right" | "left" | "top" | "bottom";
  /** Runs before the step is shown (navigate, open the menu...). */
  before?: () => void | Promise<void>;
};

type Box = { top: number; left: number; width: number; height: number };
const PAD = 8;
const CARD_W = 390;

function visibleElement(selector?: string): HTMLElement | null {
  if (!selector) return null;
  const nodes = Array.from(document.querySelectorAll<HTMLElement>(selector));
  return nodes.find((el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== "hidden"; }) ?? null;
}

export default function Tour({ steps, onClose }: { steps: TourStep[]; onClose: (completed: boolean) => void }) {
  const [index, setIndex] = useState(0);
  const [box, setBox] = useState<Box | null>(null);
  const [cardPos, setCardPos] = useState<{ top: number; left: number } | null>(null);
  const [narrow, setNarrow] = useState(window.innerWidth < 700);
  const card = useRef<HTMLDivElement>(null);
  const nextButton = useRef<HTMLButtonElement>(null);
  const step = steps[index];
  const last = index === steps.length - 1;

  const measure = useCallback(() => {
    setNarrow(window.innerWidth < 700);
    const el = visibleElement(step.target);
    if (!el) { setBox(null); return; }
    const r = el.getBoundingClientRect();
    setBox({ top: r.top - PAD, left: r.left - PAD, width: r.width + PAD * 2, height: r.height + PAD * 2 });
  }, [step]);

  // Run the step's navigation, wait for the screen to render, then find and show its element.
  useEffect(() => {
    let cancelled = false;
    let frames = 0;
    let raf = 0;
    (async () => {
      await step.before?.();
      await new Promise((resolve) => window.setTimeout(resolve, 380));
      if (cancelled) return;
      visibleElement(step.target)?.scrollIntoView({ block: "center", inline: "nearest", behavior: "auto" });
      // Follow the element for a moment: menus and pages animate into place.
      const tick = () => { if (cancelled) return; measure(); if (frames++ < 40) raf = requestAnimationFrame(tick); };
      tick();
    })();
    return () => { cancelled = true; cancelAnimationFrame(raf); };
  }, [step, measure]);

  useEffect(() => {
    const onChange = () => measure();
    window.addEventListener("resize", onChange);
    window.addEventListener("scroll", onChange, true);
    return () => { window.removeEventListener("resize", onChange); window.removeEventListener("scroll", onChange, true); };
  }, [measure]);

  // Place the card beside the highlighted element, inside the screen.
  useLayoutEffect(() => {
    const el = card.current;
    if (!el) return;
    const w = Math.min(CARD_W, window.innerWidth - 24);
    const h = el.offsetHeight;
    const vw = window.innerWidth, vh = window.innerHeight;
    if (!box || narrow) { setCardPos(narrow ? { top: vh - h - 12, left: (vw - w) / 2 } : { top: Math.max(16, (vh - h) / 2), left: (vw - w) / 2 }); return; }
    const gap = 16;
    const fits = {
      right: box.left + box.width + gap + w <= vw - 12,
      left: box.left - gap - w >= 12,
      bottom: box.top + box.height + gap + h <= vh - 12,
      top: box.top - gap - h >= 12,
    };
    const order = [step.placement ?? "right", "right", "bottom", "left", "top"] as const;
    const side = order.find((s) => fits[s]) ?? "center";
    let top: number, left: number;
    if (side === "right") { left = box.left + box.width + gap; top = box.top; }
    else if (side === "left") { left = box.left - gap - w; top = box.top; }
    else if (side === "bottom") { top = box.top + box.height + gap; left = box.left; }
    else if (side === "top") { top = box.top - gap - h; left = box.left; }
    else { top = (vh - h) / 2; left = (vw - w) / 2; }
    setCardPos({ top: Math.max(12, Math.min(top, vh - h - 12)), left: Math.max(12, Math.min(left, vw - w - 12)) });
  }, [box, narrow, index, step.placement]);

  useEffect(() => { nextButton.current?.focus(); }, [index]);
  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      if (event.key === "Escape") { event.stopPropagation(); onClose(false); }
      else if (event.key === "ArrowRight" || event.key === "Enter" && document.activeElement?.tagName !== "BUTTON") { if (last) onClose(true); else setIndex((i) => i + 1); }
      else if (event.key === "ArrowLeft") setIndex((i) => Math.max(0, i - 1));
    };
    document.addEventListener("keydown", key, true);
    return () => document.removeEventListener("keydown", key, true);
  }, [last, onClose]);

  const width = Math.min(CARD_W, window.innerWidth - 24);
  return createPortal(
    <div className="tour-root" role="presentation">
      <div className="tour-block" onClick={(event) => event.stopPropagation()} />
      {box ? <div className="tour-spot" style={{ top: box.top, left: box.left, width: box.width, height: box.height }} /> : <div className="tour-dim" />}
      <div ref={card} className="tour-card" role="dialog" aria-modal="true" aria-labelledby="tour-title" style={{ width, top: cardPos?.top ?? 0, left: cardPos?.left ?? 0, opacity: cardPos ? 1 : 0 }}>
        <button type="button" className="tour-x" aria-label="Close tour" onClick={() => onClose(false)}><X size={16} /></button>
        <small className="tour-count">Step {index + 1} of {steps.length}</small>
        <h2 id="tour-title">{step.title}</h2>
        <div className="tour-body">{step.body}</div>
        <div className="tour-progress" aria-hidden="true"><i style={{ width: `${((index + 1) / steps.length) * 100}%` }} /></div>
        <div className="tour-actions">
          <button type="button" className="tour-skip" onClick={() => onClose(false)}>{last ? "Close" : "Skip tour"}</button>
          <span>
            {index > 0 && <button type="button" className="outline" onClick={() => setIndex(index - 1)}><ArrowLeft size={15} /> Back</button>}
            <button ref={nextButton} type="button" className="primary" onClick={() => (last ? onClose(true) : setIndex(index + 1))}>{last ? "Finish" : "Next"} {!last && <ArrowRight size={15} />}</button>
          </span>
        </div>
      </div>
    </div>,
    document.body,
  );
}
