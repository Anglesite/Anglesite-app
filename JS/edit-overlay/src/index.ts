// Entry point: install the overlay once the DOM is parsed.
//
// The bundle is injected by WKWebView at `atDocumentEnd`, so when this runs the document is
// usually past `loading` — fall through to immediate install in that case.

import { install } from "./overlay.js";

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", install, { once: true });
} else {
  install();
}
