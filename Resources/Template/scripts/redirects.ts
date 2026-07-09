import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { AstroIntegration } from "astro";

export interface RedirectEntry {
  source: string;
  destination: string;
  code: 301 | 302;
}

/// Returns `true` if `entry` has the shape `readRedirects` requires: `source`/`destination` are
/// non-empty strings, `source` starts with `/`, and `code` is exactly `301` or `302`.
function isValidRedirectEntry(entry: unknown): entry is RedirectEntry {
  if (typeof entry !== "object" || entry === null) return false;
  const e = entry as Record<string, unknown>;
  return (
    typeof e.source === "string" &&
    e.source.length > 0 &&
    e.source.startsWith("/") &&
    typeof e.destination === "string" &&
    e.destination.length > 0 &&
    (e.code === 301 || e.code === 302)
  );
}

/// Reads `redirects.json` from the site root. Returns `[]` if the file is missing entirely — a
/// site with no redirects yet is the normal, silent case. If the file is present but fails to
/// parse (hand-edited, or left mid-merge-conflict), or if it parses but individual entries are
/// malformed, this warns via `console.warn` (surfaced in Astro's build/dev logs) so the site
/// owner notices, while still returning a best-effort result so the build never hard-fails —
/// malformed individual entries are dropped rather than propagated to Astro's own `redirects`
/// config, which throws on an invalid entry shape.
export function readRedirects(siteRoot: string): RedirectEntry[] {
  const path = resolve(siteRoot, "redirects.json");
  let raw: string;
  try {
    raw = readFileSync(path, "utf-8");
  } catch {
    return [];
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    console.warn(`[anglesite-redirects] redirects.json exists but is not valid JSON: ${err}`);
    return [];
  }

  if (!Array.isArray(parsed)) {
    console.warn("[anglesite-redirects] redirects.json must contain a JSON array; ignoring its contents.");
    return [];
  }

  const valid = parsed.filter(isValidRedirectEntry);
  const droppedCount = parsed.length - valid.length;
  if (droppedCount > 0) {
    console.warn(
      `[anglesite-redirects] dropped ${droppedCount} malformed redirect ${droppedCount === 1 ? "entry" : "entries"} from redirects.json.`,
    );
  }
  return valid;
}

/// Cloudflare Pages' `_redirects` plain-text format: one `source destination code` line per
/// entry, trailing newline. See https://developers.cloudflare.com/pages/configuration/redirects/
export function buildCloudflareRedirectsFile(entries: RedirectEntry[]): string {
  if (entries.length === 0) return "";
  return entries.map((e) => `${e.source} ${e.destination} ${e.code}`).join("\n") + "\n";
}

/// Astro's `redirects` config shape: a map of source path to `{ status, destination }`.
export function toAstroRedirectsConfig(entries: RedirectEntry[]): Record<string, { status: 301 | 302; destination: string }> {
  const config: Record<string, { status: 301 | 302; destination: string }> = {};
  for (const e of entries) {
    config[e.source] = { status: e.code, destination: e.destination };
  }
  return config;
}

/// Wires `redirects.json` into both the dev-server preview (Astro's own `redirects` config, via
/// `astro:config:setup`) and the production Cloudflare Pages output (a generated `dist/_redirects`
/// file, via `astro:build:done` — Astro's static output has no adapter here, so its own
/// `redirects` config only emits HTML meta-refresh pages, not real HTTP redirects; `_redirects`
/// is what Cloudflare Pages actually serves).
export default function redirects(): AstroIntegration {
  // Captured from `astro:config:setup`, which Astro guarantees runs before `astro:build:done`.
  // Reused there instead of re-deriving the site root from the output `dir` (fragile: it assumed
  // `outDir` always ends in a literal "dist").
  let siteRoot: string | undefined;

  return {
    name: "anglesite-redirects",
    hooks: {
      "astro:config:setup": ({ config, updateConfig }) => {
        siteRoot = fileURLToPath(config.root);
        const entries = readRedirects(siteRoot);
        if (entries.length === 0) return;
        updateConfig({ redirects: toAstroRedirectsConfig(entries) });
      },
      "astro:build:done": ({ dir }) => {
        if (!siteRoot) return;
        const entries = readRedirects(siteRoot);
        if (entries.length === 0) return;
        writeFileSync(resolve(fileURLToPath(dir), "_redirects"), buildCloudflareRedirectsFile(entries));
      },
    },
  };
}
