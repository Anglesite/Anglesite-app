import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, extname } from "node:path";
import { mf2 } from "microformats-parser";

/** Base URL used to resolve relative u-* URLs during parsing. */
const BASE_URL = "https://example.com";

/** The mf2 root types our entry layouts may emit. */
export const ENTRY_TYPES = ["h-entry", "h-review", "h-event"] as const;
export type EntryType = (typeof ENTRY_TYPES)[number];

/** Routed collection dirs whose built pages carry an entry microformat. */
export const ENTRY_DIRS = [
  "blog", "notes", "articles", "photos", "albums",
  "bookmarks", "replies", "likes", "announcements", "events", "reviews",
];

type Mf2Item = { type: string[]; properties: Record<string, unknown[]> };

const isEntryType = (t: string): t is EntryType =>
  (ENTRY_TYPES as readonly string[]).includes(t);

/** Parse HTML and return its root microformat items. */
export function findRoots(html: string, baseUrl = BASE_URL): Mf2Item[] {
  return mf2(html, { baseUrl }).items as Mf2Item[];
}

function has(item: Mf2Item, prop: string): boolean {
  const v = item.properties[prop];
  return Array.isArray(v) && v.length > 0;
}

/**
 * Validate a single built entry page's microformats. Returns a list of human-readable
 * problems; an empty list means the page is valid mf2 for our purposes.
 */
export function validateEntryHtml(html: string, label: string, baseUrl = BASE_URL): string[] {
  const problems: string[] = [];
  const roots = findRoots(html, baseUrl).filter((i) => i.type.some(isEntryType));

  if (roots.length === 0) {
    problems.push(`${label}: no h-entry/h-review/h-event root item found`);
    return problems;
  }
  if (roots.length > 1) {
    problems.push(`${label}: expected exactly one entry root, found ${roots.length}`);
  }

  const item = roots[0];
  const type = item.type.find(isEntryType) as EntryType;

  // Every entry needs a permalink.
  if (!has(item, "url")) problems.push(`${label}: ${type} missing u-url`);

  // Dates: events use dt-start; entries and reviews use dt-published.
  if (type === "h-event") {
    if (!has(item, "start")) problems.push(`${label}: h-event missing dt-start`);
  } else if (!has(item, "published")) {
    problems.push(`${label}: ${type} missing dt-published`);
  }

  if (type === "h-review" && !has(item, "rating")) {
    problems.push(`${label}: h-review missing p-rating`);
  }

  // p-name: required and explicit for h-review/h-event (both always carry a title).
  // h-entry is intentionally name-OPTIONAL — notes, photos, replies and likes are
  // legitimately nameless mf2 entries, so we neither require a name nor apply the
  // implied-name guard to them.
  if (type === "h-review" || type === "h-event") {
    if (!has(item, "name")) {
      problems.push(`${label}: ${type} missing p-name`);
    } else {
      // Guard the implied-name pitfall (see Hreview.astro): when an h-review/h-event has
      // no explicit p-name, the parser IMPLIES a name from the element's full text, which
      // includes the e-content body. A valid explicit title never contains the whole body,
      // so a name that (after whitespace normalization) contains the content body is the
      // signal of an implied name. Normalizing both sides keeps the substring check robust
      // to inline markup / whitespace differences between the two parsed values.
      const collapse = (s: string) => s.replace(/\s+/g, " ").trim();
      const name = collapse(String(item.properties.name?.[0] ?? ""));
      const content = collapse(
        String((item.properties.content?.[0] as { value?: string } | undefined)?.value ?? ""),
      );
      if (name && content && name.includes(content)) {
        problems.push(`${label}: ${type} p-name looks implied (contains the content body) — add an explicit p-name`);
      }
    }
  }

  return problems;
}

function walkHtml(dir: string): string[] {
  const out: string[] = [];
  let names: string[];
  try {
    names = readdirSync(dir);
  } catch {
    return out; // dir absent (collection had no built pages) — not an error here
  }
  for (const name of names) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) out.push(...walkHtml(full));
    else if (extname(full) === ".html") out.push(full);
  }
  return out;
}

/**
 * Validate every built entry page under `distDir` and assert vocabulary coverage:
 * each of h-entry / h-review / h-event appears in at least one valid page.
 */
export function validateDist(distDir: string): string[] {
  const problems: string[] = [];
  const seen = new Set<string>();

  for (const sub of ENTRY_DIRS) {
    const base = join(distDir, sub);
    for (const file of walkHtml(base)) {
      const rel = file.slice(base.length + 1); // "welcome/index.html" or "index.html"
      if (!rel.includes("/")) continue; // skip the collection's own list page (index.html)
      const html = readFileSync(file, "utf8");
      const label = file.slice(distDir.length + 1);
      const pageProblems = validateEntryHtml(html, label);
      problems.push(...pageProblems);
      if (pageProblems.length === 0) {
        for (const r of findRoots(html)) for (const t of r.type) if (isEntryType(t)) seen.add(t);
      }
    }
  }

  for (const t of ENTRY_TYPES) {
    if (!seen.has(t)) problems.push(`coverage: no valid ${t} page found in ${distDir}`);
  }
  return problems;
}
