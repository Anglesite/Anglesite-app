import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { buildRobotsTxt, buildSecurityTxt, aiCrawlers, normalizeContentSignal } from "./edge-artifacts";

test("buildRobotsTxt: allows all crawlers by default and ends with a newline", () => {
  const out = buildRobotsTxt();
  assert.match(out, /^User-agent: \*$/m);
  assert.match(out, /^Disallow:\s*$/m);
  assert.match(out, /\n$/);
  assert.doesNotMatch(out, /GPTBot/);
});

test("committed public/robots.txt is byte-identical to buildRobotsTxt()", () => {
  const committed = readFileSync(
    resolve(dirname(fileURLToPath(import.meta.url)), "../public/robots.txt"),
    "utf-8",
  );
  assert.equal(buildRobotsTxt(), committed);
});

test("buildRobotsTxt(blockAI=true): blocks every crawler in aiCrawlers", () => {
  const out = buildRobotsTxt(true);
  assert.match(out, /^User-agent: \*$/m, "still has the allow-all baseline");
  for (const bot of aiCrawlers) {
    assert.match(out, new RegExp(`User-agent: ${bot}\\nDisallow: /`), `${bot} has Disallow: /`);
  }
});

test("buildRobotsTxt(blockAI=true): includes BLOCK_AI comment", () => {
  const out = buildRobotsTxt(true);
  assert.match(out, /# AI crawler \/ training bot directives \(BLOCK_AI=true in \.site-config\)/);
});

test("buildRobotsTxt: omits Content-Signal when contentSignal is undefined", () => {
  assert.doesNotMatch(buildRobotsTxt(), /Content-Signal/);
});

test("buildRobotsTxt: emits Content-Signal directive in the default group", () => {
  const out = buildRobotsTxt(false, "search=yes, ai-train=no");
  assert.match(out, /^User-agent: \*$/m);
  assert.match(out, /^Content-Signal: search=yes, ai-train=no$/m);
});

test("buildRobotsTxt: Content-Signal directive precedes any AI-blocking User-agent groups", () => {
  const out = buildRobotsTxt(true, "search=yes, ai-train=no");
  const signalIndex = out.indexOf("Content-Signal:");
  const secondUserAgentIndex = out.indexOf("User-agent:", out.indexOf("User-agent:") + 1);
  assert.ok(signalIndex > -1 && secondUserAgentIndex > -1);
  assert.ok(signalIndex < secondUserAgentIndex, "Content-Signal must stay in the User-agent: * group");
});

test("buildRobotsTxt: no blank line between Disallow: and Content-Signal (stays in the same group)", () => {
  const out = buildRobotsTxt(false, "search=yes, ai-train=no");
  const between = out.slice(out.indexOf("Disallow:"), out.indexOf("Content-Signal:"));
  assert.doesNotMatch(
    between,
    /\n\n/,
    "a blank line here would end the User-agent: * record under classic robots.txt grouping",
  );
});

test("normalizeContentSignal: undefined/empty input yields undefined", () => {
  assert.equal(normalizeContentSignal(undefined), undefined);
  assert.equal(normalizeContentSignal(""), undefined);
  assert.equal(normalizeContentSignal("   "), undefined);
});

test("normalizeContentSignal: normalizes whitespace around valid pairs", () => {
  assert.equal(
    normalizeContentSignal(" search=yes ,  ai-input=no,ai-train=no "),
    "search=yes, ai-input=no, ai-train=no",
  );
});

test("normalizeContentSignal: drops unrecognized keys and values", () => {
  assert.equal(normalizeContentSignal("search=yes, bogus=no, ai-train=maybe"), "search=yes");
});

test("normalizeContentSignal: all-invalid input yields undefined", () => {
  assert.equal(normalizeContentSignal("bogus=yes, ai-train=maybe"), undefined);
});

test("normalizeContentSignal: a later duplicate key wins, keeping first-seen key order", () => {
  assert.equal(normalizeContentSignal("search=yes, search=no"), "search=no");
  assert.equal(
    normalizeContentSignal("search=yes, ai-train=no, search=no"),
    "search=no, ai-train=no",
  );
});

const NOW = new Date("2026-06-28T12:00:00Z");

test("buildSecurityTxt: returns null when no contact configured", () => {
  assert.equal(buildSecurityTxt(undefined, "https://example.com", NOW), null);
  assert.equal(buildSecurityTxt("  ", "https://example.com", NOW), null);
});

test("buildSecurityTxt: unrecognized contact (no scheme, no @) returns null", () => {
  // Neither a URI nor an email — skip rather than emit an invalid RFC 9116 Contact.
  assert.equal(buildSecurityTxt("example.com", "https://example.com", NOW), null);
  assert.equal(buildSecurityTxt("+15005550006", "https://example.com", NOW), null);
});

test("buildSecurityTxt: bare email gets a mailto: scheme", () => {
  const out = buildSecurityTxt("security@example.com", "https://example.com", NOW);
  assert.ok(out !== null);
  assert.match(out, /^Contact: mailto:security@example\.com$/m);
});

test("buildSecurityTxt: a URL or mailto contact is used as-is", () => {
  const url = buildSecurityTxt("https://example.com/report", "https://example.com", NOW);
  assert.ok(url !== null);
  assert.match(url, /^Contact: https:\/\/example\.com\/report$/m);
  const mailto = buildSecurityTxt("mailto:s@example.com", "https://example.com", NOW);
  assert.ok(mailto !== null);
  assert.match(mailto, /^Contact: mailto:s@example\.com$/m);
});

test("buildSecurityTxt: Expires is one year out at UTC midnight", () => {
  const out = buildSecurityTxt("security@example.com", "https://example.com", NOW);
  assert.ok(out !== null);
  assert.match(out, /^Expires: 2027-06-28T00:00:00\.000Z$/m);
});

test("buildSecurityTxt: includes a Canonical URL and trailing newline", () => {
  const out = buildSecurityTxt("security@example.com", "https://example.com", NOW);
  assert.ok(out !== null);
  assert.match(out, /^Canonical: https:\/\/example\.com\/\.well-known\/security\.txt$/m);
  assert.match(out, /\n$/);
});
