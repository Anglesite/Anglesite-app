import test from "node:test";
import assert from "node:assert/strict";
import { parseAllowedDomains, buildCSP, buildHeaders } from "./csp";

test("parseAllowedDomains: empty config yields no domains", () => {
  assert.deepEqual(parseAllowedDomains(""), []);
});

test("parseAllowedDomains: dedupes, trims, sorts, drops blanks", () => {
  const cfg = "SCRIPT_ALLOW=js.stripe.com, app.cal.com ,,js.stripe.com, ";
  assert.deepEqual(parseAllowedDomains(cfg), ["app.cal.com", "js.stripe.com"]);
});

test("buildCSP: baseline when no integrations configured", () => {
  assert.equal(
    buildCSP(""),
    "default-src 'self'; script-src 'self' static.cloudflareinsights.com; " +
      "style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; " +
      "connect-src 'self' cloudflareinsights.com; frame-src 'self'; " +
      "frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
  );
});

test("buildCSP: a configured domain lands in script/frame/connect/img only", () => {
  const csp = buildCSP("SCRIPT_ALLOW=giscus.app");
  // present in the four embed directives
  assert.match(csp, /script-src 'self' static\.cloudflareinsights\.com giscus\.app;/);
  assert.match(csp, /img-src 'self' data: giscus\.app;/);
  assert.match(csp, /connect-src 'self' cloudflareinsights\.com giscus\.app;/);
  assert.match(csp, /frame-src 'self' giscus\.app;/);
  // absent from a non-embed directive
  assert.match(csp, /style-src 'self' 'unsafe-inline';/);
  assert.ok(!/style-src[^;]*giscus\.app/.test(csp));
});

test("buildHeaders: includes security headers, CSP, and astro caching", () => {
  const out = buildHeaders("SCRIPT_ALLOW=js.stripe.com");
  assert.match(out, /^\/\*\n/);
  assert.match(out, /X-Frame-Options: DENY/);
  assert.match(out, /X-Content-Type-Options: nosniff/);
  assert.match(out, /Content-Security-Policy: .*js\.stripe\.com/);
  assert.match(out, /\/_astro\/\*\n  Cache-Control: public, max-age=31536000, immutable\n$/);
});
