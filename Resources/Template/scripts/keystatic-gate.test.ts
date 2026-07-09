import test from "node:test";
import assert from "node:assert/strict";
import { isKeystaticDev } from "./keystatic-gate";

test("astro dev registers Keystatic", () => {
  assert.equal(isKeystaticDev(["node", "astro", "dev"]), true);
});

test("astro build does not register Keystatic", () => {
  assert.equal(isKeystaticDev(["node", "astro", "build"]), false);
});

test("astro preview does not register Keystatic", () => {
  assert.equal(isKeystaticDev(["node", "astro", "preview"]), false);
});

test("astro check does not register Keystatic", () => {
  assert.equal(isKeystaticDev(["node", "astro", "check"]), false);
});

test("astro build --mode dev does not register Keystatic (--mode value, not the subcommand)", () => {
  assert.equal(isKeystaticDev(["node", "astro", "build", "--mode", "dev"]), false);
});
