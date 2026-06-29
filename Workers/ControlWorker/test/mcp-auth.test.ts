import { describe, it, expect } from "vitest";
import {
  extractBearer,
  safeEqual,
  isAuthorized,
  mcpAuthMiddleware,
  mcpAuthUpgradeGuard,
} from "../in-guest/mcp-auth.js";
import http from "node:http";
import net from "node:net";

describe("extractBearer", () => {
  it("extracts token from Bearer header", () => {
    expect(extractBearer("Bearer my-token")).toBe("my-token");
  });

  it("returns empty for missing header", () => {
    expect(extractBearer(undefined)).toBe("");
  });

  it("returns empty for non-Bearer scheme", () => {
    expect(extractBearer("Basic abc")).toBe("");
  });

  it("returns empty for bare Bearer with no token", () => {
    expect(extractBearer("Bearer ")).toBe("");
  });
});

describe("safeEqual", () => {
  it("returns true for equal strings", () => {
    expect(safeEqual("abc", "abc")).toBe(true);
  });

  it("returns false for different strings", () => {
    expect(safeEqual("abc", "abd")).toBe(false);
  });
});

describe("isAuthorized", () => {
  const token = "a".repeat(64);

  it("accepts valid Bearer token", () => {
    expect(isAuthorized(`Bearer ${token}`, token)).toBe(true);
  });

  it("rejects missing header", () => {
    expect(isAuthorized(undefined, token)).toBe(false);
  });

  it("rejects wrong token", () => {
    expect(isAuthorized(`Bearer ${"b".repeat(64)}`, token)).toBe(false);
  });
});

describe("mcpAuthMiddleware", () => {
  const token = "a".repeat(64);
  const middleware = mcpAuthMiddleware(token);

  it("calls next() for valid token", () => {
    let nextCalled = false;
    const req = {
      headers: { authorization: `Bearer ${token}` },
    } as http.IncomingMessage;
    const res = {
      writeHead: () => {},
      end: () => {},
    } as unknown as http.ServerResponse;
    middleware(req, res, () => {
      nextCalled = true;
    });
    expect(nextCalled).toBe(true);
  });

  it("returns 401 for missing token", () => {
    let statusCode = 0;
    const req = { headers: {} } as http.IncomingMessage;
    const res = {
      writeHead: (code: number) => {
        statusCode = code;
      },
      end: () => {},
    } as unknown as http.ServerResponse;
    middleware(req, res, () => {});
    expect(statusCode).toBe(401);
  });

  it("returns 401 for wrong token", () => {
    let statusCode = 0;
    const req = {
      headers: { authorization: "Bearer wrong" },
    } as http.IncomingMessage;
    const res = {
      writeHead: (code: number) => {
        statusCode = code;
      },
      end: () => {},
    } as unknown as http.ServerResponse;
    middleware(req, res, () => {});
    expect(statusCode).toBe(401);
  });
});

describe("mcpAuthUpgradeGuard", () => {
  const token = "a".repeat(64);

  function makeSocket() {
    const state = { written: "", destroyed: false };
    const socket = {
      write: (data: string) => { state.written += data; },
      destroy: () => { state.destroyed = true; },
    } as unknown as net.Socket;
    return { socket, state };
  }

  it("returns true for valid Bearer token", () => {
    const req = { headers: { authorization: `Bearer ${token}` } } as http.IncomingMessage;
    const { socket, state } = makeSocket();
    expect(mcpAuthUpgradeGuard(token, req, socket)).toBe(true);
    expect(state.written).toBe("");
    expect(state.destroyed).toBe(false);
  });

  it("returns false and sends 401 for missing token", () => {
    const req = { headers: {} } as http.IncomingMessage;
    const { socket, state } = makeSocket();
    expect(mcpAuthUpgradeGuard(token, req, socket)).toBe(false);
    expect(state.written).toContain("401");
    expect(state.destroyed).toBe(true);
  });

  it("returns false and sends 401 for wrong token", () => {
    const req = { headers: { authorization: "Bearer wrong" } } as http.IncomingMessage;
    const { socket, state } = makeSocket();
    expect(mcpAuthUpgradeGuard(token, req, socket)).toBe(false);
    expect(state.written).toContain("401");
    expect(state.destroyed).toBe(true);
  });
});
