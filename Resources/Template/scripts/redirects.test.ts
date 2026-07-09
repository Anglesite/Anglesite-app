import test from "node:test";
import assert from "node:assert/strict";
import { buildCloudflareRedirectsFile, toAstroRedirectsConfig } from "./redirects";
import type { RedirectEntry } from "./redirects";

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
