import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildCloudflareRedirectsFile, readRedirects, toAstroRedirectsConfig } from "./redirects";
import type { RedirectEntry } from "./redirects";

/// Temporarily replaces `console.warn` for the duration of `fn`, recording calls, then restores it.
function withWarnSpy<T>(fn: (calls: unknown[][]) => T): T {
  const calls: unknown[][] = [];
  const original = console.warn;
  console.warn = (...args: unknown[]) => {
    calls.push(args);
  };
  try {
    return fn(calls);
  } finally {
    console.warn = original;
  }
}

function makeTempSiteRoot(): string {
  return mkdtempSync(join(tmpdir(), "anglesite-redirects-test-"));
}

test("buildCloudflareRedirectsFile: formats one line per entry as 'source destination code'", () => {
  const entries: RedirectEntry[] = [
    { source: "/old", destination: "/new", code: 301 },
    { source: "/temp", destination: "/dest", code: 302 },
  ];
  const out = buildCloudflareRedirectsFile(entries);
  assert.equal(out, "/old /new 301\n/temp /dest 302\n");
});

test("buildCloudflareRedirectsFile: empty entries produce an empty string", () => {
  assert.equal(buildCloudflareRedirectsFile([]), "");
});

test("toAstroRedirectsConfig: maps entries to Astro's { source: { destination, status } } shape", () => {
  const entries: RedirectEntry[] = [{ source: "/old", destination: "/new", code: 301 }];
  assert.deepEqual(toAstroRedirectsConfig(entries), {
    "/old": { status: 301, destination: "/new" },
  });
});

test("readRedirects: missing file returns [] quietly, without warning", () => {
  const siteRoot = makeTempSiteRoot();
  try {
    const calls = withWarnSpy((calls) => {
      const result = readRedirects(siteRoot);
      assert.deepEqual(result, []);
      return calls;
    });
    assert.equal(calls.length, 0, "console.warn should not be called when redirects.json is simply absent");
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});

test("readRedirects: present-but-invalid JSON returns [] and warns", () => {
  const siteRoot = makeTempSiteRoot();
  writeFileSync(join(siteRoot, "redirects.json"), "not json {");
  try {
    const calls = withWarnSpy((calls) => {
      const result = readRedirects(siteRoot);
      assert.deepEqual(result, []);
      return calls;
    });
    assert.ok(calls.length >= 1, "console.warn should be called when redirects.json exists but fails to parse");
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});

test("readRedirects: drops individually malformed entries but keeps valid ones, and warns", () => {
  const siteRoot = makeTempSiteRoot();
  const raw = JSON.stringify([
    { source: "/old", destination: "/new", code: 301 },
    { source: "/missing-code", destination: "/dest" },
    { source: "/bad-code", destination: "/dest", code: 307 },
    { source: "/temp", destination: "/dest2", code: 302 },
  ]);
  writeFileSync(join(siteRoot, "redirects.json"), raw);
  try {
    const calls = withWarnSpy((calls) => {
      const result = readRedirects(siteRoot);
      assert.deepEqual(result, [
        { source: "/old", destination: "/new", code: 301 },
        { source: "/temp", destination: "/dest2", code: 302 },
      ]);
      return calls;
    });
    assert.ok(calls.length >= 1, "console.warn should be called when individual entries are dropped");
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});
