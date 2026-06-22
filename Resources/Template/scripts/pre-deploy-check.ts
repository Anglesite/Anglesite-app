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
import { existsSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { readConfigFromString } from "./config";

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
  const allow = (readConfigFromString(configContent, "SCRIPT_ALLOW") ?? "")
    .split(",")
    .map((d) => d.trim())
    .filter((d) => d.length > 0);
  for (const domain of allow) {
    if (!cspLine.includes(domain)) {
      issues.push({
        severity: "error",
        message: `Configured integration domain "${domain}" is missing from the CSP.`,
        file: "_headers",
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
    issues.push({ severity: "warning", message: "No dist/ directory found — nothing to scan." });
    return issues;
  }

  const headersContent = existsSync(HEADERS_FILE) ? await readFile(HEADERS_FILE, "utf-8") : null;
  const configContent = existsSync(CONFIG_FILE) ? await readFile(CONFIG_FILE, "utf-8") : "";
  issues.push(...checkHeaders(headersContent, configContent));

  for await (const file of walk(DIST_DIR)) {
    if (!/\.(html?|js|css|json|xml|txt)$/i.test(file)) continue;
    const content = await readFile(file, "utf-8");
    const rel = relative(process.cwd(), file);

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
    }
  }

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
