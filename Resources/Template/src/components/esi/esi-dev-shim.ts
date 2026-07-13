/** Structural subset of `Element` this module needs — lets tests pass a hand-rolled fake
 *  instead of pulling in a DOM-emulation dependency this template toolchain doesn't otherwise use. */
export interface EsiFragmentElement {
  getAttribute(name: string): string | null;
  setAttribute(name: string, value: string): void;
  hasAttribute(name: string): boolean;
  innerHTML: string;
}

/** Structural subset of `Document` this module needs. */
export interface EsiFragmentDocument {
  querySelectorAll(selector: string): ArrayLike<EsiFragmentElement>;
}

const RESOLVED_ATTR = "data-esi-dev-resolved";

/**
 * Dev-preview approximation of `@dwk/esi`'s fragment resolution: fetches each unresolved
 * `<esi:include>` element's `src`, applying the same onerror/alt rules the real processor uses
 * (`docs/superpowers/specs/2026-07-13-esi-astro-component-design.md` §4), so local preview shows
 * something close to what production will. Dev-only — never bundled into a production build
 * (see `EsiInclude.astro`'s `{import.meta.env.DEV && (...)}` guard).
 */
export async function resolveEsiFragments(
  doc: EsiFragmentDocument,
  fetchImpl: (url: string) => Promise<Response>
): Promise<void> {
  const elements = Array.from(doc.querySelectorAll("esi\\:include"));
  await Promise.all(
    elements.map(async (el) => {
      if (el.hasAttribute(RESOLVED_ATTR)) return;
      const src = el.getAttribute("src");
      if (!src) {
        el.setAttribute(RESOLVED_ATTR, "true");
        return;
      }
      const onerror = el.getAttribute("onerror");
      const alt = el.getAttribute("alt");

      let body = await fetchFragmentBody(src, fetchImpl);
      if (body === null && onerror !== "continue" && alt) {
        body = await fetchFragmentBody(alt, fetchImpl);
      }
      if (body !== null) el.innerHTML = body;
      el.setAttribute(RESOLVED_ATTR, "true");
    })
  );
}

async function fetchFragmentBody(
  url: string,
  fetchImpl: (url: string) => Promise<Response>
): Promise<string | null> {
  try {
    const res = await fetchImpl(url);
    if (!res.ok) return null;
    return await res.text();
  } catch {
    return null;
  }
}

/** Reads the query-parameter toggle the app's Debug Pane Server section appends to the preview
 *  URL when "Unprocessed" mode is selected (spec §4a). */
export function esiPreviewIsUnprocessed(search: string): boolean {
  return new URLSearchParams(search).get("esiPreview") === "unprocessed";
}
