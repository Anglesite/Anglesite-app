import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import type { AstroIntegration } from "astro";

export interface RedirectEntry {
  source: string;
  destination: string;
  code: 301 | 302;
}

/// Reads `redirects.json` from the site root. Returns `[]` if the file is missing or malformed —
/// a site with no redirects yet, or one mid-edit, should never fail the build.
export function readRedirects(siteRoot: string): RedirectEntry[] {
  try {
    const raw = readFileSync(resolve(siteRoot, "redirects.json"), "utf-8");
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed;
  } catch {
    return [];
  }
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
  return {
    name: "anglesite-redirects",
    hooks: {
      "astro:config:setup": ({ config, updateConfig }) => {
        const entries = readRedirects(fileURLToPathSafe(config.root));
        if (Object.keys(entries).length === 0) return;
        updateConfig({ redirects: toAstroRedirectsConfig(entries) });
      },
      "astro:build:done": ({ dir }) => {
        const siteRoot = fileURLToPathSafe(dir).replace(/dist\/?$/, "");
        const entries = readRedirects(siteRoot);
        if (entries.length === 0) return;
        writeFileSync(resolve(fileURLToPathSafe(dir), "_redirects"), buildCloudflareRedirectsFile(entries));
      },
    },
  };
}

function fileURLToPathSafe(url: URL): string {
  return url.pathname;
}
