import test from "node:test";
import assert from "node:assert/strict";
import { checkHeaders, checkMixedContent } from "./pre-deploy-check";

const GOOD = `/*
  Content-Security-Policy: default-src 'self'; frame-src 'self' js.stripe.com
`;

test("missing _headers is an error", () => {
  const issues = checkHeaders(null, "");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "error");
  assert.match(issues[0].message, /not enforced/);
});

test("_headers without a CSP is an error", () => {
  const issues = checkHeaders("/*\n  X-Frame-Options: DENY\n", "");
  assert.equal(issues.length, 1);
  assert.match(issues[0].message, /no Content-Security-Policy/);
});

test("configured domain missing from CSP is an error naming the domain", () => {
  const issues = checkHeaders(GOOD, "SCRIPT_ALLOW=js.stripe.com,giscus.app");
  assert.equal(issues.length, 1);
  assert.match(issues[0].message, /giscus\.app/);
});

test("CSP covering all configured domains passes", () => {
  assert.deepEqual(checkHeaders(GOOD, "SCRIPT_ALLOW=js.stripe.com"), []);
});

test("no SCRIPT_ALLOW: a present CSP passes", () => {
  assert.deepEqual(checkHeaders(GOOD, ""), []);
});

test("multiple configured domains missing from CSP each produce an error", () => {
  const issues = checkHeaders(GOOD, "SCRIPT_ALLOW=giscus.app,assets.calendly.com");
  assert.equal(issues.length, 2);
  assert.ok(issues.every((i) => i.severity === "error"));
  assert.ok(issues.some((i) => /giscus\.app/.test(i.message)));
  assert.ok(issues.some((i) => /assets\.calendly\.com/.test(i.message)));
});

test("substring of an allowed domain does not satisfy coverage", () => {
  const headers = `/*\n  Content-Security-Policy: default-src 'self'; frame-src 'self' app.cal.com\n`;
  const issues = checkHeaders(headers, "SCRIPT_ALLOW=cal.com");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "error");
  assert.match(issues[0].message, /cal\.com/);
});

test("checkMixedContent: flags an insecure src", () => {
  const issues = checkMixedContent('<img src="http://example.com/a.png">', "dist/index.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "warning");
  assert.match(issues[0].message, /mixed content/i);
  assert.equal(issues[0].file, "dist/index.html");
});

test("checkMixedContent: flags an insecure url() in CSS", () => {
  const issues = checkMixedContent("body { background: url(http://x.com/bg.png); }", "dist/a.css");
  assert.equal(issues.length, 1);
});

test("checkMixedContent: https and relative refs are clean", () => {
  const ok = '<img src="https://x.com/a.png"><script src="/local.js"></script>';
  assert.deepEqual(checkMixedContent(ok, "dist/index.html"), []);
});

test("checkMixedContent: svg xmlns http URL is not flagged", () => {
  const svg = '<svg xmlns="http://www.w3.org/2000/svg"></svg>';
  assert.deepEqual(checkMixedContent(svg, "dist/index.html"), []);
});

test("checkMixedContent: at most one issue per file", () => {
  const two = '<img src="http://a.com/1.png"><img src="http://b.com/2.png">';
  assert.equal(checkMixedContent(two, "dist/index.html").length, 1);
});
