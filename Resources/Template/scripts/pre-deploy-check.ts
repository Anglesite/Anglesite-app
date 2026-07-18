#!/usr/bin/env npx tsx
/**
 * Pre-deploy security scan. Runs from the scaffolded site directory (not the template).
 *
 * Checks:
 * - No PII patterns (emails, phone numbers) in generated output
 * - No exposed API tokens or secrets
 * - No third-party tracking scripts
 * - No Keystatic admin routes in production output
 *
 * Usage: npx tsx scripts/pre-deploy-check.ts [--json] [--strict]
 *
 * Exit code 0: all clear. Exit code 1: issues found.
 * With --json: prints the versioned {version, ok, failures, warnings} envelope (#742).
 * With --strict: warnings are promoted into `failures` (both in the --json envelope and for
 * exit-code purposes) — used by `npm run build:ci`, the single entry point for non-interactive
 * runners (#799), where a warning-only issue must still block an automated bake/deploy.
 */

import { readdir, readFile, stat } from "node:fs/promises";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseAllowedDomains } from "./csp";

interface Issue {
  severity: "error" | "warning";
  category: string;
  message: string;
  file?: string;
}

interface ScanReport {
  version: 1;
  ok: boolean;
  failures: Issue[];
  warnings: Issue[];
}

const JSON_MODE = process.argv.includes("--json");
const STRICT_MODE = process.argv.includes("--strict");
const DIST_DIR = join(process.cwd(), "dist");
const HEADERS_FILE = join(DIST_DIR, "_headers");
const CONFIG_FILE = join(process.cwd(), ".site-config");

const PII_PATTERNS = [
  { name: "email", pattern: /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g },
  { name: "phone", pattern: /\b\d{3}[-.]?\d{3}[-.]?\d{4}\b/g },
  { name: "SSN", pattern: /\b\d{3}-\d{2}-\d{4}\b/g },
];

const SECRET_PATTERNS = [
  { name: "API key", pattern: /(?:api[_-]?key|apikey)\s*[:=]\s*["']?[a-zA-Z0-9_-]{20,}/gi },
  { name: "AWS key", pattern: /AKIA[0-9A-Z]{16}/g },
  { name: "private key", pattern: /-----BEGIN (?:RSA |EC )?PRIVATE KEY-----/g },
];

// Trackers with no first-party integration in this catalog. Google Analytics/Tag
// Manager are deliberately absent — the `tracking` integration (ga4 provider) makes
// them a supported, owner-opted-in choice, the same way Plausible/Fathom always were.
const BLOCKED_SCRIPTS = [
  /facebook\.net.*fbevents/i,
  /hotjar\.com/i,
];

const BLOCKED_ROUTES = [/\/keystatic(?:\/|$)/i, /\/api\/keystatic/i];

async function* walk(dir: string): AsyncGenerator<string> {
  const entries = await readdir(dir, { withFileTypes: true });
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) yield* walk(full);
    else yield full;
  }
}

/**
 * Validate the generated CSP. Returns one error Issue per problem:
 * missing _headers, no CSP directive, or a configured SCRIPT_ALLOW domain
 * absent from the CSP.
 */
export function checkHeaders(headersContent: string | null, configContent: string): Issue[] {
  const issues: Issue[] = [];
  if (headersContent === null) {
    issues.push({ severity: "error", category: "csp-misconfigured", message: "No dist/_headers — CSP is not enforced.", file: "_headers" });
    return issues;
  }
  const cspLine = headersContent
    .split("\n")
    .map((l) => l.trim())
    .find((l) => l.startsWith("Content-Security-Policy:"));
  if (!cspLine) {
    issues.push({ severity: "error", category: "csp-misconfigured", message: "dist/_headers has no Content-Security-Policy.", file: "_headers" });
    return issues;
  }
  const cspTokens = new Set(
    cspLine
      .replace(/^Content-Security-Policy:/, "")
      .split(/[\s;]+/)
      .filter((t) => t.length > 0),
  );
  const allow = parseAllowedDomains(configContent);
  for (const domain of allow) {
    if (!cspTokens.has(domain)) {
      issues.push({
        severity: "error",
        category: "csp-misconfigured",
        message: `Configured integration domain "${domain}" is missing from the CSP.`,
        file: "_headers",
      });
    }
  }
  return issues;
}

/**
 * Scan built content for likely PII (email, phone, SSN). An email that appears only as a
 * `mailto:` link target is published intent — e.g. a contact-form fallback the site owner
 * deliberately configured — not accidental exposure, so it's stripped before the email check.
 * Phone/SSN patterns are unaffected. One issue per pattern per file, matching the prior inline
 * scan's behavior.
 */
export function checkPII(content: string, file: string): Issue[] {
  const issues: Issue[] = [];
  const withoutMailtoLinks = content.replace(
    /mailto:[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g,
    "",
  );
  for (const { name, pattern } of PII_PATTERNS) {
    pattern.lastIndex = 0;
    const haystack = name === "email" ? withoutMailtoLinks : content;
    if (pattern.test(haystack)) {
      issues.push({
        severity: "error",
        category: `pii-${name.toLowerCase()}`,
        message: `Possible ${name} found`,
        file,
      });
    }
  }
  return issues;
}

/**
 * Insecure (http://) subresource references in built HTML/CSS. Targets resource
 * attributes (`src`) and CSS `url(...)` only — NOT `href` — so anchor links and
 * `xmlns="http://..."` declarations do not false-positive. Advisory: slice A's
 * `upgrade-insecure-requests` auto-upgrades these at runtime. One issue per file.
 */
export function checkMixedContent(content: string, file: string): Issue[] {
  const patterns = [/\bsrc\s*=\s*["']http:\/\//i, /url\(\s*["']?http:\/\//i];
  for (const pattern of patterns) {
    if (pattern.test(content)) {
      return [{ severity: "warning", category: "mixed-content", message: "Mixed content: insecure http:// resource reference", file }];
    }
  }
  return [];
}

/**
 * External (absolute or protocol-relative) <script> and stylesheet <link> tags
 * with a subresource-integrity problem: either missing `integrity`, or carrying
 * `integrity` without the `crossorigin` attribute it requires — the browser
 * blocks the response on CORS before integrity is evaluated, so the resource
 * silently fails to load. Heuristic tag-level regex match; multi-line tag
 * attributes are not matched. One issue per offending tag.
 */
export function checkSRI(content: string, file: string): Issue[] {
  const issues: Issue[] = [];
  const tagPattern = /<(script|link)\b[^>]*>/gi;
  let m: RegExpExecArray | null;
  while ((m = tagPattern.exec(content)) !== null) {
    const tag = m[0];
    const isScript = m[1].toLowerCase() === "script";
    const urlAttr = isScript
      ? /\bsrc\s*=\s*["'](?:https?:)?\/\//i
      : /\bhref\s*=\s*["'](?:https?:)?\/\//i;
    if (!urlAttr.test(tag)) continue;
    if (!isScript && !/\brel\s*=\s*["'][^"']*stylesheet/i.test(tag)) continue;
    const kind = isScript ? "script" : "stylesheet";
    if (!/\bintegrity\s*=/i.test(tag)) {
      issues.push({ severity: "warning", category: "sri-missing", message: `External ${kind} without subresource integrity (SRI)`, file });
    } else if (!/\scrossorigin\b/i.test(tag)) {
      issues.push({
        severity: "warning",
        category: "sri-missing",
        message: `External ${kind} has integrity but is missing crossorigin (will fail CORS)`,
        file,
      });
    }
  }
  return issues;
}

/**
 * Anchors that open a new tab (`target="_blank"`) without `rel="noopener"`,
 * which can expose `window.opener`. `rel="noreferrer"` also implies noopener
 * (per the HTML spec and all modern browsers), so either token is accepted.
 * Advisory — modern browsers imply noopener, but explicit is safer. One issue
 * per offending anchor.
 */
export function checkExternalLinkRel(content: string, file: string): Issue[] {
  const issues: Issue[] = [];
  const anchorPattern = /<a\b[^>]*>/gi;
  let m: RegExpExecArray | null;
  while ((m = anchorPattern.exec(content)) !== null) {
    const tag = m[0];
    if (!/\btarget\s*=\s*["']_blank["']/i.test(tag)) continue;
    const relMatch = tag.match(/\brel\s*=\s*["']([^"']*)["']/i);
    const rel = relMatch ? relMatch[1].toLowerCase() : "";
    if (!/\bnoopener\b|\bnoreferrer\b/.test(rel)) {
      issues.push({ severity: "warning", category: "external-link-rel", message: 'Link with target="_blank" missing rel="noopener"', file });
    }
  }
  return issues;
}

/**
 * Warn when expected security artifacts are absent from the built output.
 * `scripts/edge-artifacts.ts` (C1) generates these at build: robots.txt always,
 * security.txt only when `SECURITY_CONTACT` is set in `.site-config`.
 */
export function checkArtifactPresence(relPaths: string[]): Issue[] {
  const set = new Set(relPaths.map((p) => p.replace(/\\/g, "/")));
  const required = ["dist/robots.txt", "dist/.well-known/security.txt"];
  const issues: Issue[] = [];
  for (const path of required) {
    if (!set.has(path)) {
      issues.push({
        severity: "warning",
        category: "missing-security-artifact",
        message: `Missing security artifact: ${path.replace(/^dist\//, "")}`,
        file: path,
      });
    }
  }
  return issues;
}

async function scan(): Promise<Issue[]> {
  const issues: Issue[] = [];

  try {
    await stat(DIST_DIR);
  } catch {
    issues.push({ severity: "warning", category: "missing-security-artifact", message: "No dist/ directory found — nothing to scan." });
    return issues;
  }

  const headersContent = await readFile(HEADERS_FILE, "utf-8").catch((e: NodeJS.ErrnoException) =>
    e.code === "ENOENT" ? null : Promise.reject(e),
  );
  const configContent = await readFile(CONFIG_FILE, "utf-8").catch((e: NodeJS.ErrnoException) =>
    e.code === "ENOENT" ? "" : Promise.reject(e),
  );
  issues.push(...checkHeaders(headersContent, configContent));

  const relPaths: string[] = [];

  for await (const file of walk(DIST_DIR)) {
    if (!/\.(html?|js|css|json|xml|txt)$/i.test(file)) continue;
    const content = await readFile(file, "utf-8");
    const rel = relative(process.cwd(), file);
    relPaths.push(rel);

    issues.push(...checkPII(content, rel));

    for (const { name, pattern } of SECRET_PATTERNS) {
      pattern.lastIndex = 0;
      if (pattern.test(content)) {
        issues.push({ severity: "error", category: "exposed-token", message: `Possible ${name} exposed`, file: rel });
      }
    }

    if (/\.(html?|css)$/i.test(file)) {
      issues.push(...checkMixedContent(content, rel));
    }

    if (/\.html?$/i.test(file)) {
      for (const pattern of BLOCKED_SCRIPTS) {
        if (pattern.test(content)) {
          issues.push({
            severity: "warning",
            category: "third-party-script",
            message: `Third-party tracking script detected: ${pattern.source}`,
            file: rel,
          });
        }
      }

      for (const pattern of BLOCKED_ROUTES) {
        if (pattern.test(content)) {
          issues.push({
            severity: "error",
            category: "keystatic-route",
            message: "Keystatic admin route found in production output",
            file: rel,
          });
        }
      }

      issues.push(...checkSRI(content, rel));
      issues.push(...checkExternalLinkRel(content, rel));
    }
  }

  issues.push(...checkArtifactPresence(relPaths));

  return issues;
}

async function main() {
  const issues = await scan();
  let failures = issues.filter((i) => i.severity === "error");
  let warnings = issues.filter((i) => i.severity === "warning");

  if (STRICT_MODE) {
    failures = failures.concat(warnings);
    warnings = [];
  }

  if (JSON_MODE) {
    const report: ScanReport = { version: 1, ok: failures.length === 0, failures, warnings };
    process.stdout.write(JSON.stringify(report, null, 2) + "\n");
  } else {
    if (issues.length === 0) {
      console.log("Pre-deploy check passed — no issues found.");
    } else {
      for (const issue of issues) {
        const prefix = issue.severity === "error" ? "ERROR" : "WARN";
        const loc = issue.file ? ` (${issue.file})` : "";
        console.log(`[${prefix}] ${issue.message}${loc}`);
      }
    }
  }

  process.exit(failures.length > 0 ? 1 : 0);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
