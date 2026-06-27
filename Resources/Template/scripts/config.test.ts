import test from "node:test";
import assert from "node:assert/strict";
import { asBookingProvider, asDonationsProvider } from "./config";

test("asBookingProvider: passes through recognized providers", () => {
  assert.equal(asBookingProvider("cal"), "cal");
  assert.equal(asBookingProvider("calendly"), "calendly");
});

test("asBookingProvider: rejects unrecognized or empty values", () => {
  assert.equal(asBookingProvider("zoom"), undefined);
  assert.equal(asBookingProvider(""), undefined);
  assert.equal(asBookingProvider(undefined), undefined);
});

test("asDonationsProvider: passes through recognized providers", () => {
  assert.equal(asDonationsProvider("stripe"), "stripe");
  assert.equal(asDonationsProvider("liberapay"), "liberapay");
  assert.equal(asDonationsProvider("github-sponsors"), "github-sponsors");
});

test("asDonationsProvider: rejects unrecognized or empty values", () => {
  assert.equal(asDonationsProvider("patreon"), undefined);
  assert.equal(asDonationsProvider(""), undefined);
  assert.equal(asDonationsProvider(undefined), undefined);
});
