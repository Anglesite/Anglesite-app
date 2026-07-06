/**
 * Component-harness canvas module. Active only on /_anglesite/component/*
 * pages (the Component Editor's isolated canvas). Read-only in slice 1:
 * reports clicks as structured selections + computed styles to native, and
 * exposes highlight hooks so the native outline can drive the canvas.
 */

const HARNESS_PREFIX = "/_anglesite/component/";
const RING_CLASS = "anglesite-canvas-ring";

// Curated list shown in the inspector's Computed section.
const REPORTED_PROPERTIES = [
  "display", "position", "width", "height",
  "margin-top", "margin-right", "margin-bottom", "margin-left",
  "padding-top", "padding-right", "padding-bottom", "padding-left",
  "font-family", "font-size", "font-weight", "line-height",
  "color", "background-color", "border-radius",
] as const;

export interface SourceLoc {
  file: string;
  line: number;
  column: number;
}

export function isHarnessPage(): boolean {
  return location.pathname.startsWith(HARNESS_PREFIX);
}

export function sourceLoc(el: Element): SourceLoc | null {
  let node: Element | null = el;
  while (node && node !== document.body) {
    const loc = node.getAttribute("data-astro-source-loc");
    const file = node.getAttribute("data-astro-source-file");
    if (loc && file) {
      const [line, column] = loc.split(":").map(Number);
      return { file, line: line ?? 0, column: column ?? 0 };
    }
    node = node.parentElement;
  }
  return null;
}

export function installComponentCanvas(): void {
  if (!isHarnessPage()) return;
  document.addEventListener("click", onClick, true);
  (window as unknown as Record<string, unknown>).anglesiteCanvas = {
    highlight(line: number, column: number): void {
      clearRing();
      const el = document.querySelector(`[data-astro-source-loc="${line}:${column}"]`);
      if (el) drawRing(el);
    },
    clear: clearRing,
  };
}

function onClick(event: MouseEvent): void {
  const target = event.target instanceof Element ? event.target : null;
  if (!target) return;
  event.preventDefault();
  event.stopPropagation();
  const loc = sourceLoc(target);
  post({
    type: "anglesite:canvas-selection",
    file: loc?.file ?? null,
    line: loc?.line ?? null,
    column: loc?.column ?? null,
  });
  reportComputedStyles(target);
  clearRing();
  drawRing(target);
}

function reportComputedStyles(el: Element): void {
  const computed = getComputedStyle(el);
  const styles: Record<string, string> = {};
  for (const property of REPORTED_PROPERTIES) {
    styles[property] = computed.getPropertyValue(property);
  }
  post({ type: "anglesite:computed-styles", styles });
}

function drawRing(el: Element): void {
  const rect = el.getBoundingClientRect();
  const ring = document.createElement("div");
  ring.className = RING_CLASS;
  ring.style.cssText =
    `position:absolute;pointer-events:none;z-index:2147483646;` +
    `border:2px solid #0a84ff;border-radius:2px;` +
    `left:${rect.left + scrollX - 2}px;top:${rect.top + scrollY - 2}px;` +
    `width:${rect.width}px;height:${rect.height}px;`;
  document.body.appendChild(ring);
}

function clearRing(): void {
  document.querySelectorAll(`.${RING_CLASS}`).forEach((n) => n.remove());
}

interface WebKitHost {
  webkit?: { messageHandlers?: { anglesite?: { postMessage(msg: unknown): void } } };
}

function post(msg: unknown): void {
  (window as WebKitHost).webkit?.messageHandlers?.anglesite?.postMessage(msg);
}
