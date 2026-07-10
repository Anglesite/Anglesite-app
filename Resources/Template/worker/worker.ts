/**
 * Per-site Cloudflare Worker entry point.
 *
 * Composes @dwk/* social endpoints behind the site's static assets, plus a runtime inbox-capture
 * endpoint (#587) that does NOT depend on any @dwk/* package — Webmention's link-verification
 * shape and Micropub's IndieAuth-gated shape don't fit a public "visitor sends us a message"
 * form, so this route is bespoke. It stages submissions into the `INBOX_KV` namespace for the
 * app to pull and commit into the site's git working copy the next time it opens
 * (Sources/AnglesiteCore/InboxSubmissionSync.swift).
 *
 * Static assets are served by the [assets] binding in wrangler.toml; this Worker handles only
 * the social + inbox endpoint paths. When neither is enabled, this file is not referenced
 * (wrangler.toml has no `main` entry and deploys static-only).
 */

// Placeholder — V-2.1 (#353) will wire the actual @dwk/* imports here.
// The composition pattern follows @dwk/workers' documented model:
//
//   import { createIndieAuth } from "@dwk/indieauth";
//   import { createWebmention } from "@dwk/webmention";
//
//   const indieauth = createIndieAuth({ baseUrl });
//   const webmention = createWebmention({ baseUrl });
//
//   export default {
//     async fetch(request, env, ctx) {
//       const url = new URL(request.url);
//       if (url.pathname.startsWith("/.well-known/indieauth"))
//         return indieauth.fetch(request, env, ctx);
//       if (url.pathname.startsWith("/webmention"))
//         return webmention.fetch(request, env, ctx);
//       return env.ASSETS.fetch(request);
//     }
//   };

/** Minimal Workers KV surface this file needs — avoids a `@cloudflare/workers-types` dependency
 *  the template doesn't otherwise have. */
export interface InboxKV {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>;
}

export interface WorkerEnv {
  ASSETS?: { fetch: typeof fetch };
  INBOX_KV?: InboxKV;
}

const RATE_LIMIT_WINDOW_SECONDS = 3600;
const RATE_LIMIT_MAX_PER_WINDOW = 5;
const MAX_SUBJECT_LENGTH = 200;
const MAX_FROM_LENGTH = 200;
const MAX_MESSAGE_LENGTH = 10_000;

export interface InboxFields {
  subject: string;
  from: string;
  message: string;
}

/** Validates and trims the three required fields; null if any is missing or too long. */
export function validateInboxFields(fields: Record<string, string>): InboxFields | null {
  const subject = (fields.subject ?? "").trim();
  const from = (fields.from ?? "").trim();
  const message = (fields.message ?? "").trim();
  if (!subject || !from || !message) return null;
  if (
    subject.length > MAX_SUBJECT_LENGTH ||
    from.length > MAX_FROM_LENGTH ||
    message.length > MAX_MESSAGE_LENGTH
  ) {
    return null;
  }
  return { subject, from, message };
}

/** True (and records the hit) once `ip` has submitted `RATE_LIMIT_MAX_PER_WINDOW` times within
 *  the current hour-long window. A simple KV counter, not a sliding window — good enough for a
 *  single-owner-site abuse gate; Cloudflare's own Rate Limiting Rules remain the escalation path
 *  for anything more sophisticated. */
export async function isRateLimited(kv: InboxKV, ip: string): Promise<boolean> {
  const key = `ratelimit:${ip}`;
  const raw = await kv.get(key);
  const count = raw ? Number.parseInt(raw, 10) : 0;
  if (count >= RATE_LIMIT_MAX_PER_WINDOW) return true;
  await kv.put(key, String(count + 1), { expirationTtl: RATE_LIMIT_WINDOW_SECONDS });
  return false;
}

async function parseRequestFields(request: Request): Promise<Record<string, string> | null> {
  const contentType = request.headers.get("content-type") ?? "";
  if (contentType.includes("application/json")) {
    const body = (await request.json()) as Record<string, unknown>;
    return Object.fromEntries(Object.entries(body).map(([k, v]) => [k, String(v)]));
  }
  if (
    contentType.includes("application/x-www-form-urlencoded") ||
    contentType.includes("multipart/form-data")
  ) {
    const form = await request.formData();
    return Object.fromEntries([...form.entries()].map(([k, v]) => [k, String(v)]));
  }
  return null;
}

export async function handleInbox(request: Request, env: WorkerEnv): Promise<Response> {
  if (request.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
  if (!env.INBOX_KV) return new Response("Inbox capture not configured", { status: 500 });

  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  if (ip !== "unknown" && await isRateLimited(env.INBOX_KV, ip)) {
    return new Response(null, { status: 429 });
  }

  const fields = await parseRequestFields(request);
  if (!fields) return new Response("Unsupported Content-Type", { status: 400 });

  // Honeypot: a hidden form field real visitors never fill in. Silently accept-and-drop so bots
  // get no signal they were caught, rather than a 4xx they could learn from.
  if ((fields.website ?? "").trim() !== "") {
    return new Response(null, { status: 202 });
  }

  const validated = validateInboxFields(fields);
  if (!validated) {
    return new Response("Missing or invalid field: subject, from, message", { status: 400 });
  }

  const id = crypto.randomUUID();
  const submission = { id, ...validated, receivedAt: new Date().toISOString() };
  await env.INBOX_KV.put(`inbox:${id}`, JSON.stringify(submission));

  return new Response(null, { status: 202 });
}

export default {
  async fetch(request: Request, env: WorkerEnv): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/inbox") {
      return handleInbox(request, env);
    }
    const assets = env.ASSETS;
    if (!assets) {
      return new Response("No assets binding configured", { status: 500 });
    }
    return assets.fetch(request);
  },
};
