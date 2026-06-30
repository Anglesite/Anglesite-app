import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Env } from "../src/sandbox-env.js";

const mockExec = vi.fn();
const mockStartProcess = vi.fn();
const mockTunnelsGet = vi.fn();
const mockTunnelsDrop = vi.fn();

vi.mock("@cloudflare/sandbox", () => ({
  getSandbox: () => ({
    exec: mockExec,
    startProcess: mockStartProcess,
    tunnels: { get: mockTunnelsGet, drop: mockTunnelsDrop },
  }),
  Sandbox: class {},
}));

const { default: worker } = await import("../src/worker.js");

const SECRET = "test-secret-value";
const TOKEN = "a".repeat(64);

function makeEnv(overrides: Partial<Env> = {}): Env {
  return {
    Sandbox: {} as Env["Sandbox"],
    CONTROL_API_SECRET: SECRET,
    SITE_DIR: "/workspace",
    ASTRO_PORT: "4321",
    PROXY_PORT: "8080",
    MCP_PORT: "4399",
    ...overrides,
  };
}

function authedRequest(
  path: string,
  body?: unknown,
  method = "POST",
): Request {
  return new Request(`https://worker.test${path}`, {
    method,
    headers: {
      authorization: `Bearer ${SECRET}`,
      "content-type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
  });
}

function validStartBody() {
  return {
    siteID: "my-site-123",
    gitRemote: "https://github.com/owner/repo.git",
    gitRef: "main",
    token: TOKEN,
  };
}

beforeEach(() => {
  vi.clearAllMocks();
});

describe("auth guard", () => {
  it("rejects requests without Bearer token", async () => {
    const req = new Request("https://worker.test/start", { method: "POST" });
    const res = await worker.fetch(req, makeEnv());
    expect(res.status).toBe(401);
    const body = await res.json();
    expect(body.error).toBe("unauthorized");
  });

  it("rejects requests with wrong Bearer token", async () => {
    const req = new Request("https://worker.test/start", {
      method: "POST",
      headers: { authorization: "Bearer wrong-token" },
    });
    const res = await worker.fetch(req, makeEnv());
    expect(res.status).toBe(401);
  });

  it("returns 503 when CONTROL_API_SECRET is not configured", async () => {
    const req = new Request("https://worker.test/start", { method: "POST" });
    const res = await worker.fetch(req, makeEnv({ CONTROL_API_SECRET: "" }));
    expect(res.status).toBe(503);
    const body = await res.json();
    expect(body.error).toBe("CONTROL_API_SECRET not configured");
  });
});

describe("routing", () => {
  it("returns 404 for unknown paths", async () => {
    const req = authedRequest("/unknown");
    const res = await worker.fetch(req, makeEnv());
    expect(res.status).toBe(404);
  });

  it("returns 404 for GET /start", async () => {
    const req = new Request("https://worker.test/start", {
      method: "GET",
      headers: { authorization: `Bearer ${SECRET}` },
    });
    const res = await worker.fetch(req, makeEnv());
    expect(res.status).toBe(404);
  });
});

describe("POST /start", () => {
  it("returns 400 for invalid body", async () => {
    const req = authedRequest("/start", { siteID: "" });
    const res = await worker.fetch(req, makeEnv());
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.field).toBe("siteID");
  });

  it("returns 400 for gitRef with path traversal", async () => {
    const req = authedRequest("/start", {
      ...validStartBody(),
      gitRef: "main/../etc/passwd",
    });
    const res = await worker.fetch(req, makeEnv());
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.field).toBe("gitRef");
  });

  it("returns 500 when cleanup fails", async () => {
    mockExec.mockResolvedValueOnce({ success: false, exitCode: 1 });
    const req = authedRequest("/start", validStartBody());
    const res = await worker.fetch(req, makeEnv());
    expect(res.status).toBe(500);
    const body = await res.json();
    expect(body.error).toBe("workspace cleanup failed");
  });

  it("returns 500 when clone fails", async () => {
    mockExec
      .mockResolvedValueOnce({ success: true })
      .mockResolvedValueOnce({ success: false, exitCode: 128 });
    const req = authedRequest("/start", validStartBody());
    const res = await worker.fetch(req, makeEnv());
    expect(res.status).toBe(500);
    const body = await res.json();
    expect(body.error).toBe("clone failed");
    expect(body.exitCode).toBe(128);
  });

  it("returns 500 when hydrate fails", async () => {
    mockExec
      .mockResolvedValueOnce({ success: true })
      .mockResolvedValueOnce({ success: true })
      .mockResolvedValueOnce({ success: false, exitCode: 1 });
    const req = authedRequest("/start", validStartBody());
    const res = await worker.fetch(req, makeEnv());
    expect(res.status).toBe(500);
    const body = await res.json();
    expect(body.error).toBe("hydrate failed");
  });

  it("returns previewURL and mcpURL on success", async () => {
    mockExec.mockResolvedValue({ success: true });
    mockStartProcess.mockResolvedValue(undefined);
    mockTunnelsGet
      .mockResolvedValueOnce({ url: "https://preview.trycloudflare.com" })
      .mockResolvedValueOnce({ url: "https://mcp.trycloudflare.com" });

    const req = authedRequest("/start", validStartBody());
    const res = await worker.fetch(req, makeEnv());
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.previewURL).toBe("https://preview.trycloudflare.com");
    expect(body.mcpURL).toBe("https://mcp.trycloudflare.com");
  });

  it("passes quoted shell args to sandbox.exec", async () => {
    mockExec.mockResolvedValue({ success: true });
    mockStartProcess.mockResolvedValue(undefined);
    mockTunnelsGet.mockResolvedValue({ url: "https://t.trycloudflare.com" });

    const req = authedRequest("/start", validStartBody());
    await worker.fetch(req, makeEnv());

    const cloneCall = mockExec.mock.calls.find(
      (c: string[]) => typeof c[0] === "string" && c[0].includes("git clone"),
    );
    expect(cloneCall).toBeDefined();
    expect(cloneCall![0]).toContain("'main'");
    expect(cloneCall![0]).toContain("'https://github.com/owner/repo.git'");
  });

  it("starts three processes with session token", async () => {
    mockExec.mockResolvedValue({ success: true });
    mockStartProcess.mockResolvedValue(undefined);
    mockTunnelsGet.mockResolvedValue({ url: "https://t.trycloudflare.com" });

    const req = authedRequest("/start", validStartBody());
    await worker.fetch(req, makeEnv());

    expect(mockStartProcess).toHaveBeenCalledTimes(3);
    const envs = mockStartProcess.mock.calls.map(
      (c: [string, { env?: Record<string, string> }]) => c[1]?.env,
    );
    for (const env of envs) {
      expect(env?.SESSION_TOKEN).toBe(TOKEN);
    }
  });
});

describe("POST /stop", () => {
  it("returns 400 for invalid body", async () => {
    const req = authedRequest("/stop", { siteID: "bad chars!!" });
    const res = await worker.fetch(req, makeEnv());
    expect(res.status).toBe(400);
  });

  it("drops tunnels and returns stopped on success", async () => {
    mockTunnelsDrop.mockResolvedValue(undefined);
    const req = authedRequest("/stop", { siteID: "my-site-123" });
    const res = await worker.fetch(req, makeEnv());
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.stopped).toBe(true);
    expect(mockTunnelsDrop).toHaveBeenCalledTimes(2);
  });
});

describe("error handling", () => {
  it("returns generic internal error on unhandled exception", async () => {
    mockExec.mockRejectedValueOnce(new Error("sandbox exploded"));
    const req = authedRequest("/start", validStartBody());
    const res = await worker.fetch(req, makeEnv());
    expect(res.status).toBe(500);
    const body = await res.json();
    expect(body.error).toBe("internal error");
    expect(JSON.stringify(body)).not.toContain("sandbox exploded");
  });
});
