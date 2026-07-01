import { getSandbox } from "@cloudflare/sandbox";
import { Sandbox, type Env } from "./sandbox-env.js";
import { authorized } from "./auth.js";
import {
  validateStartBody,
  validateStatusBody,
  validateStopBody,
  isValidationError,
} from "./validation.js";
import type { StartResponse, StatusResponse } from "./types.js";

export { Sandbox };

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });

function withMCPPath(rawURL: string): string {
  const url = new URL(rawURL);
  const base = url.pathname.replace(/\/$/, "");
  url.pathname = `${base}/mcp`;
  return url.toString();
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (!authorized(request, env.CONTROL_API_SECRET)) {
      return json(
        {
          error: env.CONTROL_API_SECRET
            ? "unauthorized"
            : "CONTROL_API_SECRET not configured",
        },
        env.CONTROL_API_SECRET ? 401 : 503,
      );
    }

    const url = new URL(request.url);
    const SITE_DIR = env.SITE_DIR || "/workspace";
    const ASTRO_PORT = env.ASTRO_PORT || "4321";
    const PROXY_PORT = env.PROXY_PORT || "8080";
    const MCP_PORT = env.MCP_PORT || "4399";

    try {
      if (url.pathname === "/start" && request.method === "POST") {
        const rawBody = await request.json();
        const parsed = validateStartBody(rawBody);
        if (isValidationError(parsed))
          return json(
            { error: parsed.message, field: parsed.field },
            400,
          );

        const { siteID, gitRemote, gitRef, token } = parsed;
        const sandbox = getSandbox(env.Sandbox, siteID);

        const clean = await sandbox.exec(
          `rm -rf '${SITE_DIR}'/* '${SITE_DIR}'/.[!.]*`,
        );
        if (!clean.success)
          return json({ error: "workspace cleanup failed", exitCode: clean.exitCode }, 500);

        const clone = await sandbox.exec(
          `git clone --branch '${gitRef}' --depth 1 '${gitRemote}' '${SITE_DIR}'`,
        );
        if (!clone.success)
          return json({ error: "clone failed", exitCode: clone.exitCode }, 500);

        const hydrate = await sandbox.exec(`hydrate.sh '${SITE_DIR}'`, {
          cwd: SITE_DIR,
        });
        if (!hydrate.success)
          return json({ error: "hydrate failed", exitCode: hydrate.exitCode }, 500);

        // startProcess is fire-and-forget — launch failures surface through the readiness probe below
        await sandbox.startProcess("start-dev-server.sh", {
          cwd: SITE_DIR,
          env: { SITE_DIR, PORT: ASTRO_PORT, SESSION_TOKEN: token },
        });

        await sandbox.startProcess("node /opt/anglesite/auth-proxy.js", {
          env: {
            SESSION_TOKEN: token,
            UPSTREAM_PORT: ASTRO_PORT,
            PROXY_PORT,
          },
        });

        await sandbox.startProcess("node /opt/anglesite/mcp-server.js", {
          cwd: SITE_DIR,
          env: { SESSION_TOKEN: token, MCP_PORT },
        });

        let ready = false;
        for (let i = 0; i < 60; i++) {
          const probe = await sandbox.exec(
            `curl -sf -o /dev/null 'http://localhost:${ASTRO_PORT}/'`,
          );
          if (probe.success) {
            ready = true;
            break;
          }
          await new Promise((r) => setTimeout(r, 500));
        }
        if (!ready)
          return json(
            { error: "astro dev did not become ready in 30s" },
            504,
          );

        const [previewTunnel, mcpTunnel] = await Promise.all([
          sandbox.tunnels.get(Number(PROXY_PORT)),
          sandbox.tunnels.get(Number(MCP_PORT)),
        ]);

        const response: StartResponse = {
          previewURL: previewTunnel.url,
          mcpURL: withMCPPath(mcpTunnel.url),
        };
        return json(response, 200);
      }

      if (url.pathname === "/status" && request.method === "POST") {
        const rawBody = await request.json();
        const parsed = validateStatusBody(rawBody);
        if (isValidationError(parsed))
          return json(
            { error: parsed.message, field: parsed.field },
            400,
          );

        const sandbox = getSandbox(env.Sandbox, parsed.siteID);
        const [previewProbe, mcpProbe] = await Promise.all([
          sandbox.exec(`curl -s -o /dev/null 'http://localhost:${PROXY_PORT}/'`),
          sandbox.exec(`curl -s -o /dev/null 'http://localhost:${MCP_PORT}/mcp'`),
        ]);
        const response: StatusResponse = {
          siteID: parsed.siteID,
          previewReady: previewProbe.success,
          mcpReady: mcpProbe.success,
        };
        return json(response, 200);
      }

      if (url.pathname === "/stop" && request.method === "POST") {
        const rawBody = await request.json();
        const parsed = validateStopBody(rawBody);
        if (isValidationError(parsed))
          return json(
            { error: parsed.message, field: parsed.field },
            400,
          );

        const sandbox = getSandbox(env.Sandbox, parsed.siteID);
        await Promise.allSettled([
          sandbox.tunnels.destroy(Number(PROXY_PORT)),
          sandbox.tunnels.destroy(Number(MCP_PORT)),
        ]);
        return json({ stopped: true }, 200);
      }

      return json({ error: "not found" }, 404);
    } catch (e) {
      console.error("worker unhandled error", e);
      return json({ error: "internal error" }, 500);
    }
  },
};
