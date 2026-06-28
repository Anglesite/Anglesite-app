import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { buildRobotsTxt, buildSecurityTxt } from "./edge-artifacts";

test("buildRobotsTxt: allows all crawlers and ends with a newline", () => {
  const out = buildRobotsTxt();
  assert.match(out, /^User-agent: \*$/m);
  assert.match(out, /^Disallow:\s*$/m);
  assert.match(out, /\n$/);
});

test("committed public/robots.txt is byte-identical to buildRobotsTxt()", () => {
  const committed = readFileSync(
    resolve(dirname(fileURLToPath(import.meta.url)), "../public/robots.txt"),
    "utf-8",
  );
  assert.equal(buildRobotsTxt(), committed);
});

const NOW = new Date("2026-06-28T12:00:00Z");

test("buildSecurityTxt: returns null when no contact configured", () => {
  assert.equal(buildSecurityTxt(undefined, "https://example.com", NOW), null);
  assert.equal(buildSecurityTxt("  ", "https://example.com", NOW), null);
});

test("buildSecurityTxt: bare email gets a mailto: scheme", () => {
  const out = buildSecurityTxt("security@example.com", "https://example.com", NOW);
  assert.match(out, /^Contact: mailto:security@example\.com$/m);
});

test("buildSecurityTxt: a URL or mailto contact is used as-is", () => {
  const url = buildSecurityTxt("https://example.com/report", "https://example.com", NOW);
  assert.match(url, /^Contact: https:\/\/example\.com\/report$/m);
  const mailto = buildSecurityTxt("mailto:s@example.com", "https://example.com", NOW);
  assert.match(mailto, /^Contact: mailto:s@example\.com$/m);
});

test("buildSecurityTxt: Expires is one year out at UTC midnight", () => {
  const out = buildSecurityTxt("security@example.com", "https://example.com", NOW);
  assert.match(out, /^Expires: 2027-06-28T00:00:00\.000Z$/m);
});

test("buildSecurityTxt: includes a Canonical URL and trailing newline", () => {
  const out = buildSecurityTxt("security@example.com", "https://example.com", NOW);
  assert.match(out, /^Canonical: https:\/\/example\.com\/\.well-known\/security\.txt$/m);
  assert.match(out, /\n$/);
});
