// @vitest-environment jsdom
import { describe, it, expect, beforeAll, beforeEach } from "vitest";
import { install, HOVER_CLASS, EDITABLE_CLASS } from "../src/overlay.js";

interface WebKit {
  messageHandlers: { anglesite: { postMessage: (body: unknown) => void } };
}

let sent: unknown[] = [];

function stubWebKit(): void {
  (window as unknown as { webkit: WebKit }).webkit = {
    messageHandlers: { anglesite: { postMessage: (body) => { sent.push(body); } } },
  };
}

function clearBody(): void {
  while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
}

function makeText<K extends keyof HTMLElementTagNameMap>(parent: Element, tag: K, text: string): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  el.textContent = text;
  parent.appendChild(el);
  return el;
}

// install() registers listeners on `document` and is internally idempotent. Run it once for
// the whole file so listener attachments don't accumulate across tests; reset only per-test
// state (body DOM, post recorder) in beforeEach.
beforeAll(() => {
  install();
});

beforeEach(() => {
  clearBody();
  sent = [];
  stubWebKit();
});

describe("install", () => {
  it("is idempotent: a second call does not add a duplicate <style>", () => {
    install();
    install();
    const styles = document.head.querySelectorAll("style[data-anglesite-overlay]");
    expect(styles.length).toBe(1);
  });
});

describe("hover", () => {
  it("adds the hover class when mousing over a text element", () => {
    const p = makeText(document.body, "p", "Hi");
    p.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
    expect(p.classList.contains(HOVER_CLASS)).toBe(true);
  });

  it("removes the hover class on mouseout", () => {
    const p = makeText(document.body, "p", "Hi");
    p.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
    p.dispatchEvent(new MouseEvent("mouseout", { bubbles: true }));
    expect(p.classList.contains(HOVER_CLASS)).toBe(false);
  });

  it("does not add the hover class to a non-text element like <div>", () => {
    const div = document.createElement("div");
    document.body.appendChild(div);
    div.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
    expect(div.classList.contains(HOVER_CLASS)).toBe(false);
  });
});

describe("click-to-edit", () => {
  it("flips contentEditable on a text element and adds the editing class", () => {
    const p = makeText(document.body, "p", "Hello");
    p.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    expect(p.contentEditable).toBe("true");
    expect(p.classList.contains(EDITABLE_CLASS)).toBe(true);
  });

  it("posts an EditMessage on blur when the text changed", () => {
    const main = document.createElement("main");
    document.body.appendChild(main);
    const p = makeText(main, "p", "old");

    p.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    p.textContent = "new";
    p.dispatchEvent(new FocusEvent("blur"));

    expect(sent.length).toBe(1);
    const msg = sent[0] as { type: string; op: string; selector: { tag: string; ancestors?: Array<{ tag: string }> }; value: unknown };
    expect(msg.type).toBe("anglesite:apply-edit");
    expect(msg.op).toBe("set-text");
    expect(msg.value).toBe("new");
    expect(msg.selector.tag).toBe("P");
    expect(msg.selector.ancestors?.map((a) => a.tag)).toEqual(["BODY", "MAIN"]);
  });

  it("does not post on blur when the text is unchanged", () => {
    const p = makeText(document.body, "p", "same");
    p.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    p.dispatchEvent(new FocusEvent("blur"));
    expect(sent.length).toBe(0);
  });
});
