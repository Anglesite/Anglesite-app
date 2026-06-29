import { describe, it, expect } from "vitest";
import { safeEqual, authorized } from "../src/auth.js";

describe("safeEqual", () => {
  it("returns true for identical strings", () => {
    expect(safeEqual("abc", "abc")).toBe(true);
  });

  it("returns false for different lengths", () => {
    expect(safeEqual("ab", "abc")).toBe(false);
  });

  it("returns false for one-char difference", () => {
    expect(safeEqual("abc", "abd")).toBe(false);
  });

  it("returns true for empty strings", () => {
    expect(safeEqual("", "")).toBe(true);
  });

  it("returns false for empty vs non-empty", () => {
    expect(safeEqual("", "a")).toBe(false);
  });
});

describe("authorized", () => {
  const secret = "test-secret-value";

  it("accepts a valid Bearer token", () => {
    const req = new Request("http://localhost/start", {
      headers: { Authorization: `Bearer ${secret}` },
    });
    expect(authorized(req, secret)).toBe(true);
  });

  it("rejects missing Authorization header", () => {
    const req = new Request("http://localhost/start");
    expect(authorized(req, secret)).toBe(false);
  });

  it("rejects wrong token", () => {
    const req = new Request("http://localhost/start", {
      headers: { Authorization: "Bearer wrong-token" },
    });
    expect(authorized(req, secret)).toBe(false);
  });

  it("rejects non-Bearer scheme", () => {
    const req = new Request("http://localhost/start", {
      headers: { Authorization: `Basic ${secret}` },
    });
    expect(authorized(req, secret)).toBe(false);
  });

  it("fails closed when secret is undefined", () => {
    const req = new Request("http://localhost/start", {
      headers: { Authorization: `Bearer ${secret}` },
    });
    expect(authorized(req, undefined)).toBe(false);
  });

  it("fails closed when secret is empty string", () => {
    const req = new Request("http://localhost/start", {
      headers: { Authorization: "Bearer " },
    });
    expect(authorized(req, "")).toBe(false);
  });
});
