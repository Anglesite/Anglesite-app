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
 * Usage: npx tsx scripts/pre-deploy-check.ts [--json]
 *
 * Exit code 0: all clear. Exit code 1: issues found.
 * With --json: prints a JSON array of { severity, message, file } objects.
 */

import { readdir, readFile, stat } from "node:fs/promises";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseAllowedDomains } from "./csp";

interface Issue {
  severity: "error" | "warning";
  message: string;
  file?: string;
}

const JSON_MODE = process.argv.includes("--json");
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

const BLOCKED_SCRIPTS = [
  /google-analytics\.com/i,
  /googletagmanager\.com/i,
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
    issues.push({ severity: "error", message: "No dist/_headers — CSP is not enforced.", file: "_headers" });
    return issues;
  }
  const cspLine = headersContent
    .split("\n")
    .map((l) => l.trim())
    .find((l) => l.startsWith("Content-Security-Policy:"));
  if (!cspLine) {
    issues.push({ severity: "error", message: "dist/_headers has no Content-Security-Policy.", file: "_headers" });
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
        message: `Configured integration domain "${domain}" is missing from the CSP.`,
        file: "_headers",
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
      return [{ severity: "warning", message: "Mixed content: insecure http:// resource reference", file }];
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
      issues.push({ severity: "warning", message: `External ${kind} without subresource integrity (SRI)`, file });
    } else if (!/\scrossorigin\b/i.test(tag)) {
      issues.push({
        severity: "warning",
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
      issues.push({ severity: "warning", message: 'Link with target="_blank" missing rel="noopener"', file });
    }
  }
  return issues;
}

/**
 * Warn when expected security artifacts are absent from the built output.
 * Generators for these land in slice C1 (#405); until then this is informational.
 */
export function checkArtifactPresence(relPaths: string[]): Issue[] {
  const set = new Set(relPaths.map((p) => p.replace(/\\/g, "/")));
  const required = ["dist/robots.txt", "dist/.well-known/security.txt"];
  const issues: Issue[] = [];
  for (const path of required) {
    if (!set.has(path)) {
      issues.push({ severity: "warning", message: `Missing security artifact: ${path.replace(/^dist\//, "")}`, file: path });
    }
  }
  return issues;
}

async function scan(): Promise<Issue[]> {
  const issues: Issue[] = [];

  try {
    await stat(DIST_DIR);
  } catch {
    issues.push({ severity: "warning", message: "No dist/ directory found — nothing to scan." });
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

    for (const { name, pattern } of PII_PATTERNS) {
      pattern.lastIndex = 0;
      if (pattern.test(content)) {
        issues.push({ severity: "error", message: `Possible ${name} found`, file: rel });
      }
    }

    for (const { name, pattern } of SECRET_PATTERNS) {
      pattern.lastIndex = 0;
      if (pattern.test(content)) {
        issues.push({ severity: "error", message: `Possible ${name} exposed`, file: rel });
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
            message: `Third-party tracking script detected: ${pattern.source}`,
            file: rel,
          });
        }
      }

      for (const pattern of BLOCKED_ROUTES) {
        if (pattern.test(content)) {
          issues.push({
            severity: "error",
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

  if (JSON_MODE) {
    process.stdout.write(JSON.stringify(issues, null, 2) + "\n");
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

  const hasErrors = issues.some((i) => i.severity === "error");
  process.exit(hasErrors ? 1 : 0);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
