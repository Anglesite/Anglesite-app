import { describe, it, expect } from "vitest";
import {
  extractCookie,
  safeEqual,
  isAuthorized,
  TOKEN_COOKIE_NAME,
} from "../in-guest/auth-proxy-core.js";

describe("extractCookie", () => {
  const token = "a".repeat(64);

  it("extracts the session_token cookie", () => {
    expect(extractCookie(`${TOKEN_COOKIE_NAME}=${token}`)).toBe(token);
  });

  it("extracts from multiple cookies", () => {
    expect(
      extractCookie(`foo=bar; ${TOKEN_COOKIE_NAME}=${token}; baz=qux`),
    ).toBe(token);
  });

  it("returns empty string for missing cookie", () => {
    expect(extractCookie("foo=bar")).toBe("");
  });

  it("returns empty string for undefined", () => {
    expect(extractCookie(undefined)).toBe("");
  });
});

describe("safeEqual", () => {
  it("returns true for equal strings", () => {
    expect(safeEqual("abc", "abc")).toBe(true);
  });

  it("returns false for different strings", () => {
    expect(safeEqual("abc", "abd")).toBe(false);
  });

  it("returns false for different lengths", () => {
    expect(safeEqual("ab", "abc")).toBe(false);
  });
});

describe("isAuthorized", () => {
  const token = "a".repeat(64);

  it("accepts valid cookie", () => {
    expect(isAuthorized(`${TOKEN_COOKIE_NAME}=${token}`, token)).toBe(true);
  });

  it("rejects missing cookie", () => {
    expect(isAuthorized(undefined, token)).toBe(false);
  });

  it("rejects wrong cookie value", () => {
    expect(
      isAuthorized(`${TOKEN_COOKIE_NAME}=${"b".repeat(64)}`, token),
    ).toBe(false);
  });

  it("rejects empty cookie value", () => {
    expect(isAuthorized(`${TOKEN_COOKIE_NAME}=`, token)).toBe(false);
  });
});
