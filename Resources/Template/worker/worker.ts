import {
  createIndieAuth,
  type AuthorizationRequest,
  type IndieAuthEnv,
} from "@dwk/indieauth";

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

/** Minimal Workers KV surface shared by inbox capture and consent throttling. */
export interface InboxKV {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>;
}

export interface WorkerEnv extends IndieAuthEnv {
  ASSETS?: Fetcher;
  INBOX_KV?: InboxKV;
  SOCIAL_KV?: InboxKV;
  INDIEAUTH_OWNER_PASSWORD: string;
}

const RATE_LIMIT_WINDOW_SECONDS = 3600;
const RATE_LIMIT_MAX_PER_WINDOW = 5;
const MAX_SUBJECT_LENGTH = 200;
const MAX_FROM_LENGTH = 200;
const MAX_MESSAGE_LENGTH = 10_000;
const MAX_CONSENT_BODY_BYTES = 16_384;
const CONSENT_TTL_SECONDS = 300;
const CONSENT_VERSION = 1;
const INDIEAUTH_PATHS = new Set([
  "/.well-known/oauth-authorization-server",
  "/authorize",
  "/token",
  "/revocation",
]);

interface ConsentGrant {
  v: 1;
  exp: number;
  clientId: string;
  redirectUri: string;
  state: string;
  codeChallenge: string;
  scope: string;
  resources: string[];
}

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function decodeBase64url(value: string): Uint8Array<ArrayBuffer> | null {
  try {
    const padded = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }
    return bytes;
  } catch {
    return null;
  }
}

async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

function grantFor(request: AuthorizationRequest, expiresAt: number): ConsentGrant {
  return {
    v: CONSENT_VERSION,
    exp: expiresAt,
    clientId: request.clientId,
    redirectUri: request.redirectUri,
    state: request.state,
    codeChallenge: request.codeChallenge,
    scope: request.scope,
    resources: [...(request.resources ?? [])],
  };
}

function isConsentGrant(value: unknown): value is ConsentGrant {
  if (typeof value !== "object" || value === null) return false;
  const grant = value as Record<string, unknown>;
  return grant.v === CONSENT_VERSION
    && typeof grant.exp === "number"
    && typeof grant.clientId === "string"
    && typeof grant.redirectUri === "string"
    && typeof grant.state === "string"
    && typeof grant.codeChallenge === "string"
    && typeof grant.scope === "string"
    && Array.isArray(grant.resources)
    && grant.resources.every((resource) => typeof resource === "string");
}

export async function createConsentToken(
  request: AuthorizationRequest,
  signingKey: string,
  now = Math.floor(Date.now() / 1000),
): Promise<string> {
  const payload = new TextEncoder().encode(JSON.stringify(grantFor(request, now + CONSENT_TTL_SECONDS)));
  const signature = await crypto.subtle.sign("HMAC", await hmacKey(signingKey), payload);
  return `${base64url(payload)}.${base64url(new Uint8Array(signature))}`;
}

export async function verifyConsentToken(
  token: string,
  request: AuthorizationRequest,
  signingKey: string,
  now = Math.floor(Date.now() / 1000),
): Promise<boolean> {
  if (token.length > 8_192) return false;
  const [payloadPart, signaturePart, extra] = token.split(".");
  if (!payloadPart || !signaturePart || extra !== undefined) return false;
  const payload = decodeBase64url(payloadPart);
  const signature = decodeBase64url(signaturePart);
  if (!payload || !signature) return false;
  if (!(await crypto.subtle.verify("HMAC", await hmacKey(signingKey), signature, payload))) return false;

  let decoded: unknown;
  try {
    decoded = JSON.parse(new TextDecoder().decode(payload));
  } catch {
    return false;
  }
  if (!isConsentGrant(decoded) || decoded.exp <= now) return false;
  const expected = grantFor(request, decoded.exp);
  return JSON.stringify(decoded) === JSON.stringify(expected);
}

async function secretsMatch(provided: string, expected: string, comparisonSecret: string): Promise<boolean> {
  const key = await hmacKey(comparisonSecret);
  const encoder = new TextEncoder();
  const expectedMAC = await crypto.subtle.sign("HMAC", key, encoder.encode(expected));
  // Keep both passwords as message data under one server-controlled key and delegate the MAC
  // comparison to WebCrypto instead of comparing attacker-influenced bytes in JavaScript.
  return crypto.subtle.verify("HMAC", key, expectedMAC, encoder.encode(provided));
}

function escapeHTML(value: string): string {
  return value.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "\"": "&quot;",
    "'": "&#39;",
  })[character] ?? character);
}

function consentPage(request: AuthorizationRequest): Response {
  const hidden = [
    ["client_id", request.clientId],
    ["redirect_uri", request.redirectUri],
    ["state", request.state],
    ["response_type", "code"],
    ["code_challenge", request.codeChallenge],
    ["code_challenge_method", request.codeChallengeMethod],
    ["scope", request.scope],
    ...(request.me ? [["me", request.me]] : []),
    ...(request.resources ?? []).map((resource) => ["resource", resource]),
  ].map(([name, value]) => `<input type="hidden" name="${escapeHTML(name)}" value="${escapeHTML(value)}">`).join("\n");
  const scopes = request.scopes.length > 0 ? request.scopes.map(escapeHTML).join(", ") : "identity only";
  const body = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Approve sign-in</title></head><body><main>
<h1>Approve sign-in</h1>
<p><strong>${escapeHTML(request.clientId)}</strong> wants to sign in as this site.</p>
<p>Requested access: ${scopes}</p>
<form method="post" action="/indieauth/consent">
${hidden}
<label>Site owner password <input name="password" type="password" required autocomplete="current-password" maxlength="512"></label>
<button type="submit">Approve</button>
</form></main></body></html>`;
  return new Response(body, {
    status: 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
    },
  });
}

async function readBoundedForm(request: Request): Promise<URLSearchParams | null> {
  if (!(request.headers.get("content-type") ?? "").includes("application/x-www-form-urlencoded")) return null;
  if (!request.body) return new URLSearchParams();
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_CONSENT_BODY_BYTES) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const body = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new URLSearchParams(new TextDecoder().decode(body));
}

async function consentRateLimitKey(request: Request): Promise<string> {
  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ip));
  return `indieauth-login:${base64url(new Uint8Array(digest)).slice(0, 32)}`;
}

async function isConsentRateLimited(request: Request, env: WorkerEnv): Promise<boolean> {
  if (!env.SOCIAL_KV) return false;
  const key = await consentRateLimitKey(request);
  const raw = await env.SOCIAL_KV.get(key);
  const count = raw ? Number.parseInt(raw, 10) : 0;
  if (count >= RATE_LIMIT_MAX_PER_WINDOW) return true;
  await env.SOCIAL_KV.put(key, String(count + 1), { expirationTtl: RATE_LIMIT_WINDOW_SECONDS });
  return false;
}

export async function handleIndieAuthConsent(request: Request, env: WorkerEnv): Promise<Response> {
  if (request.method !== "POST") return new Response("Method Not Allowed", { status: 405, headers: { allow: "POST" } });
  if (!env.INDIEAUTH_OWNER_PASSWORD || !env.TOKEN_SIGNING_KEY) {
    return new Response("IndieAuth secrets are not configured", { status: 503 });
  }
  if (await isConsentRateLimited(request, env)) return new Response("Too Many Requests", { status: 429 });
  const form = await readBoundedForm(request);
  if (!form) return new Response("Invalid consent form", { status: 400 });
  if (!(await secretsMatch(
    form.get("password") ?? "",
    env.INDIEAUTH_OWNER_PASSWORD,
    env.TOKEN_SIGNING_KEY,
  ))) {
    console.warn(JSON.stringify({ event: "indieauth.consent_rejected", reason: "password_invalid" }));
    return new Response("Invalid site owner password", { status: 401 });
  }

  const origin = new URL(request.url).origin;
  const authorize = new URL("/authorize", origin);
  for (const name of ["client_id", "redirect_uri", "state", "response_type", "code_challenge", "code_challenge_method", "scope", "me"]) {
    const value = form.get(name);
    if (value !== null) authorize.searchParams.set(name, value);
  }
  for (const resource of form.getAll("resource")) authorize.searchParams.append("resource", resource);
  const grant: AuthorizationRequest = {
    clientId: form.get("client_id") ?? "",
    redirectUri: form.get("redirect_uri") ?? "",
    state: form.get("state") ?? "",
    codeChallenge: form.get("code_challenge") ?? "",
    codeChallengeMethod: form.get("code_challenge_method") ?? "",
    scope: form.get("scope") ?? "",
    scopes: (form.get("scope") ?? "").split(/\s+/).filter(Boolean),
    ...(form.get("me") ? { me: form.get("me") as string } : {}),
    ...(form.getAll("resource").length > 0 ? { resources: form.getAll("resource") } : {}),
  };
  authorize.searchParams.set("consent", await createConsentToken(grant, env.TOKEN_SIGNING_KEY));
  return Response.redirect(authorize.toString(), 303);
}

function indieAuthHandler(request: Request, env: WorkerEnv) {
  const baseUrl = new URL(request.url).origin;
  return createIndieAuth({
    baseUrl,
    scopesSupported: ["create", "update", "delete", "media"],
    resourceIndicatorPolicy(resource) {
      return new URL(resource).origin === baseUrl;
    },
    async approveAuthorization(authorization) {
      const consent = new URL(request.url).searchParams.get("consent");
      if (consent && await verifyConsentToken(consent, authorization, env.TOKEN_SIGNING_KEY)) {
        return {
          me: `${baseUrl}/`,
          scopes: authorization.scopes,
          profile: { url: `${baseUrl}/` },
        };
      }
      return consentPage(authorization);
    },
  });
}

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
 *  for anything more sophisticated.
 *
 *  The get-then-put below is NOT atomic: two concurrent requests from the same IP can both read
 *  the same stale count before either write lands, so both get admitted, and Workers KV's
 *  eventual consistency (writes can take up to ~60s to propagate globally) makes this worse under
 *  a distributed burst. This makes the cap soft/best-effort — enough to deter casual abuse — not
 *  a hard guarantee; a true hard limit would need an atomic counter (e.g. a Durable Object). */
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

export async function handleInbox(
  request: Request,
  env: Pick<WorkerEnv, "INBOX_KV">,
): Promise<Response> {
  if (request.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
  if (!env.INBOX_KV) return new Response("Inbox capture not configured", { status: 500 });

  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  if (await isRateLimited(env.INBOX_KV, ip)) {
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
  async fetch(request: Request, env: WorkerEnv, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/indieauth/consent") {
      return handleIndieAuthConsent(request, env);
    }
    if (INDIEAUTH_PATHS.has(url.pathname)) {
      return indieAuthHandler(request, env)(request, env, ctx);
    }
    if (url.pathname === "/inbox") {
      return handleInbox(request, env);
    }
    const assets = env.ASSETS;
    if (!assets) {
      return new Response("No assets binding configured", { status: 500 });
    }
    return assets.fetch(request);
  },
} satisfies ExportedHandler<WorkerEnv>;
