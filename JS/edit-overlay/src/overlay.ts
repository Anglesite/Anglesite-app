// DOM behavior layer for the WKWebView edit overlay.
//
// One install per page. Mounts inline styles, wires hover / click-to-edit / image-drop, and
// installs a reply channel so native can answer edit attempts. Pure DOM manipulation — all
// JS → native messaging goes through `messages.ts`.

import { elementInfoFor } from "./selector.js";
import {
  installReplyHandler,
  nextEditID,
  postEdit,
  type EditMessage,
  type EditReply,
} from "./messages.js";
import { showToast } from "./toast.js";
import { installVisibleElementsReporter } from "./visible-elements.js";

export const HOVER_CLASS = "anglesite-hover";
export const EDITABLE_CLASS = "anglesite-editing";
const INSTALLED_FLAG = "__anglesiteOverlayInstalled" as const;
const STYLE_TAG_MARKER = "data-anglesite-overlay";

// Tags whose text content is plausibly user-editable as a unit. Conservative on purpose —
// structural containers (div, body, section, header, …) don't qualify; the selector strategy
// (#18) will let us refine this once Phase 5's source patcher knows what it can resolve.
const EDITABLE_TAG = /^(H[1-6]|P|SPAN|A|LI|EM|STRONG|BLOCKQUOTE|FIGCAPTION|CAPTION|LABEL|DT|DD)$/;

function isEditableText(el: Element): boolean {
  return EDITABLE_TAG.test(el.tagName);
}

function installStyles(): void {
  if (document.head.querySelector(`style[${STYLE_TAG_MARKER}]`)) return;
  const style = document.createElement("style");
  style.setAttribute(STYLE_TAG_MARKER, "");
  style.textContent = [
    `.${HOVER_CLASS} { outline: 2px solid rgba(0, 122, 255, 0.8); outline-offset: 2px; cursor: text; }`,
    `.${EDITABLE_CLASS} { outline: 2px solid rgba(0, 122, 255, 1); outline-offset: 2px; background: rgba(0, 122, 255, 0.05); }`,
  ].join("\n");
  document.head.appendChild(style);
}

function attachHover(): void {
  let hovered: Element | null = null;
  document.addEventListener("mouseover", (ev) => {
    const target = ev.target as Element | null;
    if (!target || target.nodeType !== 1 || !isEditableText(target)) {
      if (hovered) { hovered.classList.remove(HOVER_CLASS); hovered = null; }
      return;
    }
    if (hovered && hovered !== target) hovered.classList.remove(HOVER_CLASS);
    target.classList.add(HOVER_CLASS);
    hovered = target;
  });
  document.addEventListener("mouseout", (ev) => {
    const target = ev.target as Element | null;
    if (target?.classList.contains(HOVER_CLASS)) target.classList.remove(HOVER_CLASS);
    if (hovered === target) hovered = null;
  });
}

function attachClickToEdit(awaitReply: (id: string, handler: (r: { status: string }) => void) => void): void {
  document.addEventListener("click", (ev) => {
    const target = ev.target as HTMLElement | null;
    if (!target || target.nodeType !== 1 || !isEditableText(target)) return;
    if (target.isContentEditable) return;
    ev.preventDefault();

    target.classList.remove(HOVER_CLASS);
    // Capture the selector snapshot BEFORE any edit mutations — `textContent` (and any other
    // edit-time-mutable field) must reflect the source-file state so the server-side patcher
    // can find the element. Done after HOVER_CLASS is removed and before EDITABLE_CLASS is
    // added so the snapshot has no overlay-internal classes either.
    const originalInfo = elementInfoFor(target);
    target.contentEditable = "true";
    target.classList.add(EDITABLE_CLASS);
    target.focus();

    const originalText = target.textContent ?? "";

    const finish = () => {
      target.contentEditable = "false";
      target.classList.remove(EDITABLE_CLASS);
      const newText = target.textContent ?? "";
      if (newText === originalText) return;
      const id = nextEditID();
      const msg: EditMessage = {
        id,
        type: "anglesite:apply-edit",
        path: location.pathname,
        selector: originalInfo,
        op: "replace-text",
        value: newText,
      };
      postEdit(msg);
      awaitReply(id, () => { /* Phase 5 decides whether to revert on failure. */ });
    };

    target.addEventListener("blur", finish, { once: true });
  });
}

function attachImageDrop(awaitReply: (id: string, handler: (r: EditReply) => void) => void): void {
  document.addEventListener("dragover", (ev) => {
    const target = ev.target as Element | null;
    if (target?.tagName !== "IMG") return;
    ev.preventDefault();
  });
  document.addEventListener("drop", (ev) => {
    const target = ev.target as HTMLImageElement | null;
    if (target?.tagName !== "IMG") return;
    const file = (ev as DragEvent).dataTransfer?.files[0];
    if (!file || !file.type.startsWith("image/")) return;
    ev.preventDefault();

    // Save originals before the optimistic swap so we can revert on failure.
    const savedSrc = target.src;
    const savedSrcset = target.getAttribute("srcset");
    const blobURL = URL.createObjectURL(file);
    target.src = blobURL;
    target.removeAttribute("srcset");

    const id = nextEditID();
    let settled = false;

    const revertWithToast = (text: string): void => {
      if (settled) return;
      settled = true;
      target.src = savedSrc;
      if (savedSrcset !== null) target.setAttribute("srcset", savedSrcset);
      else target.removeAttribute("srcset");
      URL.revokeObjectURL(blobURL);
      showToast(text);
    };

    const settleOnReply = (reply: EditReply): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timeoutHandle);
      if (reply.status === "applied" && reply.result) {
        target.src = reply.result.src;
        if (reply.result.srcset !== undefined) {
          target.setAttribute("srcset", reply.result.srcset);
        } else {
          target.removeAttribute("srcset");
        }
        URL.revokeObjectURL(blobURL);
      } else {
        target.src = savedSrc;
        if (savedSrcset !== null) target.setAttribute("srcset", savedSrcset);
        else target.removeAttribute("srcset");
        URL.revokeObjectURL(blobURL);
        showToast(reply.detail ?? reply.message ?? reply.reason ?? "Image edit failed");
      }
    };

    const timeoutHandle = setTimeout(() => {
      revertWithToast("Image edit timed out");
    }, 30_000);

    awaitReply(id, settleOnReply);

    const reader = new FileReader();
    reader.onload = () => {
      const dataURL = reader.result;
      if (typeof dataURL !== "string") {
        revertWithToast("Couldn't read the dropped file");
        return;
      }
      const msg: EditMessage = {
        id,
        type: "anglesite:apply-edit",
        path: location.pathname,
        selector: elementInfoFor(target),
        op: "replace-image-src",
        value: { filename: file.name, mimeType: file.type, dataURL },
      };
      const ok = postEdit(msg);
      if (!ok) {
        clearTimeout(timeoutHandle);
        revertWithToast("Not running inside the Anglesite app");
      }
    };
    reader.onerror = () => revertWithToast("Couldn't read the dropped file");
    reader.readAsDataURL(file);
  });
}

/** Mount the overlay onto `window`/`document`. Safe to call more than once. */
export function install(): void {
  const win = window as unknown as { [INSTALLED_FLAG]?: boolean };
  if (win[INSTALLED_FLAG]) return;
  win[INSTALLED_FLAG] = true;

  installStyles();
  const { awaitReply } = installReplyHandler();
  attachHover();
  attachClickToEdit(awaitReply);
  attachImageDrop(awaitReply);
  installVisibleElementsReporter();
}
