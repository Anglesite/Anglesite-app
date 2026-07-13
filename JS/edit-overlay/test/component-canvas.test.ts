// @vitest-environment jsdom
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { installComponentCanvas, isHarnessPage, sourceLoc } from "../src/component-canvas.js";

function setPath(path: string) {
  window.history.replaceState({}, "", path);
}

function capturePosts(): unknown[] {
  const posts: unknown[] = [];
  (window as any).webkit = {
    messageHandlers: { anglesite: { postMessage: (m: unknown) => posts.push(m) } },
  };
  return posts;
}

// jsdom has no layout engine — `getBoundingClientRect()` always returns a zeroed rect and
// `elementFromPoint()` always returns null. `dropTargetAt` needs both to behave like a real
// browser for its geometry math, so these tests derive both from each element's inline
// `left`/`top`/`width`/`height` styles (the fixtures below set those explicitly).
function rectOf(el: Element): DOMRect {
  const style = (el as HTMLElement).style;
  const left = parseFloat(style.left) || 0;
  const top = parseFloat(style.top) || 0;
  const width = parseFloat(style.width) || 0;
  const height = parseFloat(style.height) || 0;
  return {
    left, top, width, height,
    right: left + width, bottom: top + height, x: left, y: top,
    toJSON() { return this; },
  } as DOMRect;
}

function stubLayout() {
  vi.spyOn(Element.prototype, "getBoundingClientRect").mockImplementation(function (this: Element) {
    return rectOf(this);
  });
  // jsdom doesn't implement `elementFromPoint` at all (not even a stub returning null), so
  // `vi.spyOn` has nothing to wrap — assign directly instead.
  (document as any).elementFromPoint = (x: number, y: number): Element | null => {
    const candidates = Array.from(document.querySelectorAll("*")).reverse();
    for (const el of candidates) {
      const r = rectOf(el);
      if (r.width > 0 && r.height > 0 && x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) {
        return el;
      }
    }
    return null;
  };
}

describe("component canvas", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
    delete (window as any).anglesiteCanvas;
  });

  it("isHarnessPage gates on the harness path prefix", () => {
    setPath("/_anglesite/component/Card");
    expect(isHarnessPage()).toBe(true);
    setPath("/about/");
    expect(isHarnessPage()).toBe(false);
  });

  it("sourceLoc walks up to the nearest annotated ancestor", () => {
    document.body.innerHTML =
      `<article data-astro-source-file="/site/src/components/Card.astro" data-astro-source-loc="7:1">` +
      `<h2><em id="inner">x</em></h2></article>`;
    const loc = sourceLoc(document.getElementById("inner")!);
    expect(loc).toEqual({ file: "/site/src/components/Card.astro", line: 7, column: 1 });
    expect(sourceLoc(document.body)).toBeNull();
  });

  it("click posts canvas-selection and computed-styles", () => {
    setPath("/_anglesite/component/Card");
    const posts = capturePosts();
    document.body.innerHTML =
      `<article data-astro-source-file="/site/src/components/Card.astro" data-astro-source-loc="7:1">hi</article>`;
    installComponentCanvas();
    (document.querySelector("article") as HTMLElement).dispatchEvent(
      new MouseEvent("click", { bubbles: true }),
    );
    const types = posts.map((p: any) => p.type);
    expect(types).toContain("anglesite:canvas-selection");
    expect(types).toContain("anglesite:computed-styles");
    const selection: any = posts.find((p: any) => p.type === "anglesite:canvas-selection");
    expect(selection.line).toBe(7);
    const styles: any = posts.find((p: any) => p.type === "anglesite:computed-styles");
    expect(typeof styles.styles.display).toBe("string");
  });

  it("exposes highlight/clear hooks for native, matching on line with an offset annotation column", () => {
    // Real-world case: Astro's dev server stamps the annotation at the END
    // of the opening tag (e.g. parse column 1 -> annotated column 23), so
    // native's requested column (the parsed start) never equals the
    // annotation's column exactly. `highlight` must still resolve it.
    setPath("/_anglesite/component/Card");
    capturePosts();
    document.body.innerHTML =
      `<article data-astro-source-file="/f.astro" data-astro-source-loc="7:23">hi</article>`;
    installComponentCanvas();
    (window as any).anglesiteCanvas.highlight(7, 1);
    expect(document.querySelector(".anglesite-canvas-ring")).not.toBeNull();
    (window as any).anglesiteCanvas.clear();
    expect(document.querySelector(".anglesite-canvas-ring")).toBeNull();
  });

  it("highlight picks the nearest following column among same-line candidates", () => {
    setPath("/_anglesite/component/Card");
    capturePosts();
    document.body.innerHTML =
      `<span id="a" data-astro-source-file="/f.astro" data-astro-source-loc="8:7"></span>` +
      `<span id="b" data-astro-source-file="/f.astro" data-astro-source-loc="8:20"></span>`;
    installComponentCanvas();
    (window as any).anglesiteCanvas.highlight(8, 5);
    let ring = document.querySelector(".anglesite-canvas-ring") as HTMLElement;
    expect(ring).not.toBeNull();
    (window as any).anglesiteCanvas.clear();

    (window as any).anglesiteCanvas.highlight(8, 15);
    ring = document.querySelector(".anglesite-canvas-ring") as HTMLElement;
    expect(ring).not.toBeNull();
  });

  it("scrub creates a single #anglesite-scrub style tag and updates its content on repeated calls", () => {
    setPath("/_anglesite/component/Card");
    document.body.innerHTML = `<article class="card">hi</article>`;
    installComponentCanvas();

    (window as any).anglesiteCanvas.scrub(".card", "color", "red");
    expect(document.querySelectorAll("#anglesite-scrub")).toHaveLength(1);
    expect(document.getElementById("anglesite-scrub")?.textContent).toContain(".card { color: red; }");

    (window as any).anglesiteCanvas.scrub(".card", "color", "blue");
    expect(document.querySelectorAll("#anglesite-scrub")).toHaveLength(1);
    expect(document.getElementById("anglesite-scrub")?.textContent).toContain(".card { color: blue; }");

    (window as any).anglesiteCanvas.clearScrub();
    expect(document.getElementById("anglesite-scrub")).toBeNull();
  });

  it("scrub rejects a value containing a brace instead of injecting extra rules", () => {
    setPath("/_anglesite/component/Card");
    document.body.innerHTML = `<article class="card">hi</article><body-marker></body-marker>`;
    installComponentCanvas();

    (window as any).anglesiteCanvas.scrub(".card", "color", "red; } body-marker { display:none");
    expect(document.getElementById("anglesite-scrub")).toBeNull();

    (window as any).anglesiteCanvas.scrub(".card", "color", "red");
    (window as any).anglesiteCanvas.scrub("} .card", "color", "red");
    expect(document.getElementById("anglesite-scrub")?.textContent).toContain(".card { color: red; }");
  });

  it("clearScrub is safe to call when no scrub tag exists", () => {
    setPath("/_anglesite/component/Card");
    installComponentCanvas();
    expect(() => (window as any).anglesiteCanvas.clearScrub()).not.toThrow();
  });
});

describe("dropTargetAt", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
    delete (window as any).anglesiteCanvas;
    setPath("/_anglesite/component/Card");
    stubLayout();
  });

  afterEach(() => {
    vi.restoreAllMocks();
    delete (document as any).elementFromPoint;
  });

  it("resolves the element under a point and reports zone=into for its middle band", () => {
    document.body.innerHTML = `<article data-astro-source-file="/src/components/Card.astro" data-astro-source-loc="1:1" style="position:absolute;left:0;top:0;width:100px;height:90px;"></article>`;
    installComponentCanvas();
    const target = (window as any).anglesiteCanvas.dropTargetAt(50, 45);
    expect(target).toEqual({ file: "/src/components/Card.astro", line: 1, column: 1, zone: "into" });
  });

  it("reports zone=before near the top edge and zone=after near the bottom edge", () => {
    document.body.innerHTML = `<article data-astro-source-file="/src/components/Card.astro" data-astro-source-loc="1:1" style="position:absolute;left:0;top:0;width:100px;height:90px;"></article>`;
    installComponentCanvas();
    expect((window as any).anglesiteCanvas.dropTargetAt(50, 5).zone).toBe("before");
    expect((window as any).anglesiteCanvas.dropTargetAt(50, 85).zone).toBe("after");
  });

  it("returns null when no annotated ancestor exists at the point", () => {
    document.body.innerHTML = `<div style="position:absolute;left:0;top:0;width:10px;height:10px;"></div>`;
    installComponentCanvas();
    expect((window as any).anglesiteCanvas.dropTargetAt(500, 500)).toBeNull();
  });

  it("measures the drop zone against the annotated ancestor's box, not a deeper unannotated child's", () => {
    document.body.innerHTML =
      `<article data-astro-source-file="/src/components/Card.astro" data-astro-source-loc="1:1" style="position:absolute;left:0;top:0;width:100px;height:90px;">` +
      `<span style="position:absolute;left:40px;top:40px;width:10px;height:5px;"></span>` +
      `</article>`;
    installComponentCanvas();
    // Point hits the inner <span> (a tiny box near the article's top edge), but the zone must
    // be computed against the <article>'s own box (the element that owns the source loc), where
    // this y falls in the middle third, not the span's box, where it would be near an edge.
    const target = (window as any).anglesiteCanvas.dropTargetAt(45, 42);
    expect(target).toEqual({ file: "/src/components/Card.astro", line: 1, column: 1, zone: "into" });
  });
});
