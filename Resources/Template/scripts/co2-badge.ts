import { co2 } from "@tgwf/co2";

/// Rendered by CO2Badge.astro instead of a real value: the page's own final byte size (which
/// includes this badge's own markup) isn't knowable until after Astro has finished rendering it,
/// so the component renders this token and a post-build step (see co2Badge() below) patches the
/// real estimate into the already-written HTML.
export const CO2_PLACEHOLDER = "__ANGLESITE_CO2_PENDING__";

const estimator = new co2({ model: "1byte" });

/// UTF-8 byte size of a page — the transfer-size proxy this badge estimates from. This measures
/// the page's own rendered HTML only, not its full asset weight (CSS/JS/images) — an honest,
/// documented approximation, not a claim of total page-weight accuracy.
export function byteLength(html: string): number {
  return Buffer.byteLength(html, "utf-8");
}

/// Grams of CO2e for one page view of `bytes`, via CO2.js's byte-based model.
/// `greenHosting` lowers the estimate when the host is on a verified green-energy provider.
export function estimateGramsPerByte(bytes: number, greenHosting?: boolean): number {
  return estimator.perByte(bytes, greenHosting);
}

/// Two-decimal display string, e.g. "0.35".
export function formatGrams(grams: number): string {
  return grams.toFixed(2);
}

/// Replaces every occurrence of CO2_PLACEHOLDER in `html` with the formatted grams value.
/// A no-op when the placeholder isn't present (the integration isn't installed on this page).
export function patchHtml(html: string, grams: number): string {
  if (!html.includes(CO2_PLACEHOLDER)) return html;
  return html.split(CO2_PLACEHOLDER).join(formatGrams(grams));
}
