import test from "node:test";
import assert from "node:assert/strict";
import { CO2_PLACEHOLDER, byteLength, estimateGramsPerByte, formatGrams, patchHtml } from "./co2-badge";

test("byteLength: counts UTF-8 bytes, not JS string length", () => {
  assert.equal(byteLength("abc"), 3);
  // "café" has 4 JS characters but 5 UTF-8 bytes (é is 2 bytes).
  assert.equal(byteLength("café"), 5);
});

test("estimateGramsPerByte: returns a positive estimate, larger for more bytes", () => {
  const small = estimateGramsPerByte(100_000);
  const large = estimateGramsPerByte(500_000);
  assert.ok(small > 0, "expected a positive grams estimate");
  assert.ok(large > small, "expected a larger page to estimate more CO2 than a smaller one");
});

test("estimateGramsPerByte: green hosting produces a lower estimate than the same bytes without it", () => {
  const notGreen = estimateGramsPerByte(100_000, false);
  const green = estimateGramsPerByte(100_000, true);
  assert.ok(green < notGreen, "green hosting should reduce the estimate");
});

test("formatGrams: renders two decimal places", () => {
  assert.equal(formatGrams(0.3456), "0.35");
  assert.equal(formatGrams(1), "1.00");
  assert.equal(formatGrams(0), "0.00");
});

test("patchHtml: replaces every occurrence of the placeholder with the formatted grams value", () => {
  const html = `<p>~${CO2_PLACEHOLDER}g CO2</p><footer>~${CO2_PLACEHOLDER}g CO2</footer>`;
  const out = patchHtml(html, 0.5);
  assert.equal(out, `<p>~0.50g CO2</p><footer>~0.50g CO2</footer>`);
});

test("patchHtml: is a no-op when the placeholder is absent", () => {
  const html = "<p>no badge here</p>";
  assert.equal(patchHtml(html, 0.5), html);
});
