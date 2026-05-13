// @vitest-environment jsdom
import { describe, it, expect, beforeEach } from "vitest";
import { cssSelectorFor } from "../src/selector.js";

function $append<K extends keyof HTMLElementTagNameMap>(parent: Element, tag: K, opts: { id?: string } = {}): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  if (opts.id) el.id = opts.id;
  parent.appendChild(el);
  return el;
}

describe("cssSelectorFor", () => {
  beforeEach(() => {
    while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
  });

  it("walks the parent chain back to <html>", () => {
    const main = $append(document.body, "main");
    const h1 = $append(main, "h1", { id: "t" });
    expect(cssSelectorFor(h1)).toBe("html > body > main > h1");
  });

  it("disambiguates siblings of the same tag with :nth-of-type", () => {
    const ul = $append(document.body, "ul");
    const a = $append(ul, "li", { id: "a" });
    const b = $append(ul, "li", { id: "b" });
    const c = $append(ul, "li", { id: "c" });
    expect(cssSelectorFor(a)).toBe("html > body > ul > li:nth-of-type(1)");
    expect(cssSelectorFor(b)).toBe("html > body > ul > li:nth-of-type(2)");
    expect(cssSelectorFor(c)).toBe("html > body > ul > li:nth-of-type(3)");
  });

  it("does not add :nth-of-type when an element is the only one of its tag among its siblings", () => {
    const div = $append(document.body, "div");
    const p = $append(div, "p");
    $append(div, "span");
    $append(div, "em");
    expect(cssSelectorFor(p)).toBe("html > body > div > p");
  });

  it("returns 'html' for the document element", () => {
    expect(cssSelectorFor(document.documentElement)).toBe("html");
  });

  it("returns just the lowercased tag for a detached element", () => {
    const detached = document.createElement("p");
    expect(cssSelectorFor(detached)).toBe("p");
  });
});
