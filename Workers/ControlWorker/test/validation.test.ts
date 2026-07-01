import { describe, it, expect } from "vitest";
import {
  validateStartBody,
  validateStatusBody,
  validateStopBody,
  isValidationError,
} from "../src/validation.js";

const validToken = "a".repeat(64);

describe("validateStartBody", () => {
  const valid = {
    siteID: "site-1",
    gitRemote: "https://github.com/Anglesite/mysite.git",
    gitRef: "main",
    token: validToken,
  };

  it("accepts a valid body", () => {
    const result = validateStartBody(valid);
    expect(isValidationError(result)).toBe(false);
    expect(result).toEqual(valid);
  });

  it("rejects null", () => {
    const result = validateStartBody(null);
    expect(isValidationError(result)).toBe(true);
  });

  it("rejects non-object", () => {
    const result = validateStartBody("string");
    expect(isValidationError(result)).toBe(true);
  });

  it("rejects missing siteID", () => {
    const result = validateStartBody({ ...valid, siteID: "" });
    expect(isValidationError(result)).toBe(true);
    if (isValidationError(result)) expect(result.field).toBe("siteID");
  });

  it("rejects non-GitHub git remote", () => {
    const result = validateStartBody({
      ...valid,
      gitRemote: "https://evil.com/repo",
    });
    expect(isValidationError(result)).toBe(true);
    if (isValidationError(result)) expect(result.field).toBe("gitRemote");
  });

  it("rejects git remote with shell metacharacters", () => {
    const result = validateStartBody({
      ...valid,
      gitRemote: "https://github.com/owner/repo;rm -rf /",
    });
    expect(isValidationError(result)).toBe(true);
  });

  it("rejects ref with shell metacharacters", () => {
    const result = validateStartBody({
      ...valid,
      gitRef: "main; rm -rf /",
    });
    expect(isValidationError(result)).toBe(true);
    if (isValidationError(result)) expect(result.field).toBe("gitRef");
  });

  it("accepts ref with slashes and dots", () => {
    const result = validateStartBody({
      ...valid,
      gitRef: "feature/my-branch.v2",
    });
    expect(isValidationError(result)).toBe(false);
  });

  it("rejects token that is not 64 hex chars", () => {
    const result = validateStartBody({ ...valid, token: "short" });
    expect(isValidationError(result)).toBe(true);
    if (isValidationError(result)) expect(result.field).toBe("token");
  });

  it("rejects token with uppercase hex", () => {
    const result = validateStartBody({ ...valid, token: "A".repeat(64) });
    expect(isValidationError(result)).toBe(true);
  });
});

describe("validateStopBody", () => {
  it("accepts a valid body", () => {
    const result = validateStopBody({ siteID: "site-1" });
    expect(isValidationError(result)).toBe(false);
    expect(result).toEqual({ siteID: "site-1" });
  });

  it("rejects missing siteID", () => {
    const result = validateStopBody({});
    expect(isValidationError(result)).toBe(true);
  });

  it("rejects empty siteID", () => {
    const result = validateStopBody({ siteID: "" });
    expect(isValidationError(result)).toBe(true);
  });
});

describe("validateStatusBody", () => {
  it("accepts a valid body", () => {
    const result = validateStatusBody({ siteID: "site-1" });
    expect(isValidationError(result)).toBe(false);
    expect(result).toEqual({ siteID: "site-1" });
  });

  it("rejects invalid siteID", () => {
    const result = validateStatusBody({ siteID: "bad chars!!" });
    expect(isValidationError(result)).toBe(true);
  });
});
