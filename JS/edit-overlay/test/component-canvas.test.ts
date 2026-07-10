// @vitest-environment jsdom
import { describe, it, expect, beforeEach } from "vitest";
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

  it("clearScrub is safe to call when no scrub tag exists", () => {
    setPath("/_anglesite/component/Card");
    installComponentCanvas();
    expect(() => (window as any).anglesiteCanvas.clearScrub()).not.toThrow();
  });
});
