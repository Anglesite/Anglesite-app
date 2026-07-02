import test from "node:test";
import assert from "node:assert/strict";
import { checkHeaders, checkMixedContent, checkSRI, checkExternalLinkRel, checkArtifactPresence, checkPII } from "./pre-deploy-check";

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

test("checkPII: flags a bare email in page content", () => {
  const issues = checkPII("<p>Contact us at hello@example.com</p>", "dist/index.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "error");
  assert.match(issues[0].message, /email/);
});

test("checkPII: does not flag an email that only appears as a mailto: link target", () => {
  const issues = checkPII('<a href="mailto:hello@example.com">Email us</a>', "dist/contact.html");
  assert.deepEqual(issues, []);
});

test("checkPII: still flags a bare email elsewhere on a page that also has a mailto link", () => {
  const html = '<a href="mailto:hello@example.com">Email us</a><p>debug: admin@internal.example.com</p>';
  const issues = checkPII(html, "dist/contact.html");
  assert.equal(issues.length, 1);
  assert.match(issues[0].message, /email/);
});

test("checkPII: still flags phone numbers regardless of mailto content", () => {
  const issues = checkPII('<a href="mailto:hello@example.com">Email</a> Call 555-123-4567', "dist/contact.html");
  assert.equal(issues.length, 1);
  assert.match(issues[0].message, /phone/);
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

test("checkSRI: external script without integrity is a warning", () => {
  const issues = checkSRI('<script src="https://cdn.x.com/a.js"></script>', "dist/index.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "warning");
  assert.match(issues[0].message, /integrity/i);
});

test("checkSRI: external script with integrity AND crossorigin is clean", () => {
  const ok = '<script src="https://cdn.x.com/a.js" integrity="sha384-abc" crossorigin="anonymous"></script>';
  assert.deepEqual(checkSRI(ok, "dist/index.html"), []);
});

test("checkSRI: integrity without crossorigin is a warning (CORS would block it)", () => {
  const issues = checkSRI('<script src="https://cdn.x.com/a.js" integrity="sha384-abc"></script>', "dist/index.html");
  assert.equal(issues.length, 1);
  assert.match(issues[0].message, /crossorigin/i);
});

test("checkSRI: relative script is clean", () => {
  assert.deepEqual(checkSRI('<script src="/local.js"></script>', "dist/index.html"), []);
});

test("checkSRI: external stylesheet link without integrity is a warning", () => {
  const issues = checkSRI('<link rel="stylesheet" href="https://cdn.x.com/a.css">', "dist/index.html");
  assert.equal(issues.length, 1);
});

test("checkSRI: non-stylesheet link is ignored", () => {
  assert.deepEqual(checkSRI('<link rel="preconnect" href="https://x.com">', "dist/index.html"), []);
});

test("checkExternalLinkRel: target=_blank without rel=noopener is a warning", () => {
  const issues = checkExternalLinkRel('<a href="https://x.com" target="_blank">x</a>', "dist/index.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "warning");
  assert.match(issues[0].message, /noopener/i);
});

test("checkExternalLinkRel: rel=noopener is clean", () => {
  const ok = '<a href="https://x.com" target="_blank" rel="noopener">x</a>';
  assert.deepEqual(checkExternalLinkRel(ok, "dist/index.html"), []);
});

test("checkExternalLinkRel: rel with noopener among others is clean", () => {
  const ok = '<a href="https://x.com" target="_blank" rel="noopener noreferrer">x</a>';
  assert.deepEqual(checkExternalLinkRel(ok, "dist/index.html"), []);
});

test("checkExternalLinkRel: rel=noreferrer alone is clean (implies noopener)", () => {
  const ok = '<a href="https://x.com" target="_blank" rel="noreferrer">x</a>';
  assert.deepEqual(checkExternalLinkRel(ok, "dist/index.html"), []);
});

test("checkExternalLinkRel: link without target=_blank is ignored", () => {
  assert.deepEqual(checkExternalLinkRel('<a href="https://x.com">x</a>', "dist/index.html"), []);
});

test("checkArtifactPresence: both present is clean", () => {
  const paths = ["dist/index.html", "dist/robots.txt", "dist/.well-known/security.txt"];
  assert.deepEqual(checkArtifactPresence(paths), []);
});

test("checkArtifactPresence: missing robots.txt is a warning", () => {
  const issues = checkArtifactPresence(["dist/index.html", "dist/.well-known/security.txt"]);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "warning");
  assert.match(issues[0].message, /robots\.txt/);
});

test("checkArtifactPresence: missing both yields two warnings", () => {
  const issues = checkArtifactPresence(["dist/index.html"]);
  assert.equal(issues.length, 2);
});

test("checkArtifactPresence: backslash paths are normalized", () => {
  const paths = ["dist\\robots.txt", "dist\\.well-known\\security.txt"];
  assert.deepEqual(checkArtifactPresence(paths), []);
});
