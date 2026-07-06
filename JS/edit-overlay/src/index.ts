// Entry point: install the overlay once the DOM is parsed.
//
// The bundle is injected by WKWebView at `atDocumentEnd`, so when this runs the document is
// usually past `loading` — fall through to immediate install in that case.
//
// Component-harness pages (`/_anglesite/component/*`) get the read-only canvas instead of the
// click-to-edit overlay — see `component-canvas.ts`.

import { install } from "./overlay.js";
import { installComponentCanvas, isHarnessPage } from "./component-canvas.js";

function boot(): void {
  if (isHarnessPage()) {
    installComponentCanvas(); // harness canvas replaces click-to-edit
  } else {
    install();
  }
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot, { once: true });
} else {
  boot();
}
