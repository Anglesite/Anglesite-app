// @vitest-environment jsdom
import { describe, it, expect, beforeAll, beforeEach, vi } from "vitest";
import {
  install,
  HOVER_CLASS,
  EDITABLE_CLASS,
  IMAGE_DROP_TARGET_CLASS,
  IMAGE_DROP_ACTIVE_CLASS,
  IMAGE_DROP_HINT_ATTRIBUTE,
} from "../src/overlay.js";

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
  // jsdom doesn't implement URL.createObjectURL / revokeObjectURL — shim them so the
  // image-drop tests can exercise the overlay behaviour without a real blob URL.
  if (typeof URL.createObjectURL === "undefined") {
    let blobCounter = 0;
    URL.createObjectURL = () => `blob:http://localhost/${++blobCounter}`;
    URL.revokeObjectURL = () => { /* no-op in test */ };
  }
  install();
});

beforeEach(() => {
  document.dispatchEvent(new Event("dragend", { bubbles: true }));
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
    expect(msg.op).toBe("replace-text");
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

  it("captures selector.textContent from the ORIGINAL text, not the edited one", () => {
    // Regression: an earlier version called `elementInfoFor(target)` inside the blur handler,
    // after the user had typed — sending the new text as `selector.textContent`. The
    // server-side patcher then couldn't find the element in the source file (which still
    // contained the original text), and no edit was applied.
    const p = makeText(document.body, "p", "original-text");
    p.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    p.textContent = "new-text-the-user-typed";
    p.dispatchEvent(new FocusEvent("blur"));

    expect(sent.length).toBe(1);
    const msg = sent[0] as { selector: { textContent?: string }; value: unknown };
    expect(msg.selector.textContent).toBe("original-text");
    expect(msg.value).toBe("new-text-the-user-typed");
  });

  it("captures a Writing Tools rewrite as a single replace-text edit (#91)", () => {
    // Apple Intelligence Writing Tools applies its rewrite inline to the DOM while the element is
    // still focused/contentEditable — modeled here by mutating `textContent` after the click but
    // before blur. The blur-time diff must then send exactly one `replace-text` apply-edit carrying
    // the rewritten text, so the rewrite lands as one undoable commit through the existing pipeline.
    const main = document.createElement("main");
    document.body.appendChild(main);
    const p = makeText(main, "p", "we makes great stuff");

    p.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    // WebKit's Writing Tools rewrite of the contentEditable element.
    p.textContent = "We make great things.";
    p.dispatchEvent(new FocusEvent("blur"));

    expect(sent.length).toBe(1);
    const msg = sent[0] as { type: string; op: string; selector: { textContent?: string }; value: unknown };
    expect(msg.type).toBe("anglesite:apply-edit");
    expect(msg.op).toBe("replace-text");
    expect(msg.value).toBe("We make great things.");
    // Selector snapshot reflects the pre-rewrite source text so the server-side patcher resolves it.
    expect(msg.selector.textContent).toBe("we makes great stuff");
  });
});

describe("image drop", () => {
  function makeImg(src: string, srcset?: string): HTMLImageElement {
    const img = document.createElement("img");
    img.src = src;
    if (srcset) img.setAttribute("srcset", srcset);
    document.body.appendChild(img);
    return img;
  }

  /** jsdom 25 doesn't implement DragEvent or DataTransfer, so we use a plain Event
   *  and define dataTransfer directly on the instance. */
  function dropOn(target: Element, file: File): void {
    const fakeDataTransfer = {
      files: [file],
      items: [{ kind: "file", type: file.type }],
      types: ["Files"],
      dropEffect: "none",
    };
    const drop = new Event("drop", { bubbles: true, cancelable: true });
    Object.defineProperty(drop, "dataTransfer", { value: fakeDataTransfer });
    target.dispatchEvent(drop);
  }

  function dragOn(type: "dragenter" | "dragover" | "dragleave", target: Element, file: File): Event {
    const fakeDataTransfer = {
      files: [file],
      items: [{ kind: "file", type: file.type }],
      types: ["Files"],
      dropEffect: "none",
    };
    const event = new Event(type, { bubbles: true, cancelable: true });
    Object.defineProperty(event, "dataTransfer", { value: fakeDataTransfer });
    target.dispatchEvent(event);
    return event;
  }

  /** jsdom's FileReader fires its onload callback after two macrotask ticks. */
  async function flushFileReader(): Promise<void> {
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
  }

  it("highlights every replaceable image while a Finder file is dragged over the page", () => {
    const first = makeImg("/images/first.jpg");
    const second = makeImg("/images/second.jpg");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });

    dragOn("dragenter", document.body, file);

    expect(first.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(true);
    expect(second.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(true);
    expect(document.querySelector(`[${IMAGE_DROP_HINT_ATTRIBUTE}]`)?.textContent).toMatch(/highlighted image/i);
  });

  it("shows which image will receive the drop", () => {
    const img = makeImg("/images/hero.jpg");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });

    const event = dragOn("dragover", img, file);

    expect(event.defaultPrevented).toBe(true);
    expect(img.classList.contains(IMAGE_DROP_ACTIVE_CLASS)).toBe(true);
  });

  it("clears image targets when the drag leaves the page", () => {
    const img = makeImg("/images/hero.jpg");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });
    dragOn("dragenter", document.body, file);

    dragOn("dragleave", document.body, file);

    expect(img.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(false);
    expect(document.querySelector(`[${IMAGE_DROP_HINT_ATTRIBUTE}]`)).toBeNull();
  });

  it("explains an image drop outside a replaceable image instead of failing silently", () => {
    makeImg("/images/hero.jpg");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });

    dropOn(document.body, file);

    expect(sent.length).toBe(0);
    expect(document.querySelector(".anglesite-toast")?.textContent).toMatch(/highlighted image/i);
  });

  it("rejects a non-image file with guidance and prevents WKWebView navigation", () => {
    const img = makeImg("/images/hero.jpg");
    const file = new File(["notes"], "notes.txt", { type: "text/plain" });

    dropOn(img, file);

    expect(sent.length).toBe(0);
    expect(img.src.endsWith("/images/hero.jpg")).toBe(true);
    expect(document.querySelector(".anglesite-toast")?.textContent).toMatch(/choose an image file/i);
  });

  it("sets img.src to a blob URL immediately on drop", async () => {
    const img = makeImg("/images/hero.jpg");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });
    dropOn(img, file);
    expect(img.src.startsWith("blob:")).toBe(true);
    // Drain the pending FileReader so it doesn't bleed into the next test.
    await flushFileReader();
  });

  it("posts apply-edit with op: replace-image-src and dataURL value", async () => {
    const img = makeImg("/images/hero.jpg");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });
    dropOn(img, file);
    await flushFileReader();
    expect(sent.length).toBe(1);
    const msg = sent[0] as { op: string; value: { filename: string; mimeType: string; dataURL: string } };
    expect(msg.op).toBe("replace-image-src");
    expect(msg.value.filename).toBe("vacation.jpg");
    expect(msg.value.mimeType).toBe("image/jpeg");
    expect(msg.value.dataURL.startsWith("data:image/jpeg;base64,")).toBe(true);
  });

  it("on edit-applied with result, swaps src/srcset and revokes the blob URL", async () => {
    const img = makeImg("/images/hero.jpg", "old-srcset");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });
    dropOn(img, file);
    await flushFileReader();
    const id = (sent[0] as { id: string }).id;

    const revokeSpy = vi.spyOn(URL, "revokeObjectURL");
    (window as unknown as { anglesite: { _handleReply: (r: unknown) => void } }).anglesite._handleReply({
      id, status: "applied", result: { src: "/images/hero.webp", srcset: "new-srcset" },
    });

    expect(img.src.endsWith("/images/hero.webp")).toBe(true);
    expect(img.getAttribute("srcset")).toBe("new-srcset");
    expect(revokeSpy).toHaveBeenCalled();
  });

  it("on edit-failed, restores original src/srcset, revokes blob URL, and shows a toast", async () => {
    const img = makeImg("/images/hero.jpg", "original-srcset");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });
    dropOn(img, file);
    await flushFileReader();
    const id = (sent[0] as { id: string }).id;

    (window as unknown as { anglesite: { _handleReply: (r: unknown) => void } }).anglesite._handleReply({
      id, status: "failed", reason: "image-optimize-failed", detail: "sharp error",
    });

    expect(img.src.endsWith("/images/hero.jpg")).toBe(true);
    expect(img.getAttribute("srcset")).toBe("original-srcset");
    expect(document.querySelector(".anglesite-toast")?.textContent).toContain("sharp error");
  });

  it("after 30s with no reply, restores original and toasts a timeout", async () => {
    vi.useFakeTimers();
    try {
      const img = makeImg("/images/hero.jpg");
      const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });
      dropOn(img, file);
      // Advance just past the 30s timeout (not runAllTimers, which would also
      // fire the toast's 4s auto-dismiss and make the assertion miss).
      await vi.advanceTimersByTimeAsync(30001);

      expect(img.src.endsWith("/images/hero.jpg")).toBe(true);
      expect(document.querySelector(".anglesite-toast")?.textContent).toMatch(/timed out/i);
    } finally {
      vi.useRealTimers();
    }
  });
});
