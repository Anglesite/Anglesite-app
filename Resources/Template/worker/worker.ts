import {
  createIndieAuth,
  type AuthorizationRequest,
  type IndieAuthEnv,
} from "@dwk/indieauth";
import {
  createWebmention,
  createWebmentionQueueConsumer,
  createD1Inbox,
  type WebmentionEnv,
  type WebmentionJob,
} from "@dwk/webmention";
import {
  createMicropub,
  type MicropubEnv,
} from "@dwk/micropub";

/**
 * Per-site Cloudflare Worker entry point.
 *
 * Composes @dwk/* social endpoints (IndieAuth, inbound Webmention, Micropub) behind the site's
 * static assets, plus a runtime inbox-capture
 * endpoint (#587) that does NOT depend on any @dwk/* package — Webmention's link-verification
 * shape and Micropub's IndieAuth-gated shape don't fit a public "visitor sends us a message"
 * form, so this route is bespoke. It stages submissions into the `INBOX_KV` namespace for the
 * app to pull and commit into the site's git working copy the next time it opens
 * (Sources/AnglesiteCore/InboxSubmissionSync.swift).
 *
 * Static assets are served by the [assets] binding in wrangler.toml; this Worker handles only
 * the social + inbox endpoint paths. When neither is enabled, this file is not referenced
 * (wrangler.toml has no `main` entry and deploys static-only).
 *
 * Routing (#746): `ROUTES` below is a declarative table mirroring the generic HTTP route claims
 * the app's Worker catalog declares for the active workers; Anglesite generates matching
 * selective `[assets].run_worker_first` entries so only these routes bypass asset-first serving.
 * The dispatcher is generic: exact/prefix matching, `405` + `Allow` for undeclared methods, HEAD
 * mirroring GET where declared, queries passed through untouched, and a true (plain-text) 404 —
 * never an HTML page — for unclaimed `/.well-known/` names, the bare directory, malformed
 * encodings, and case/trailing-slash variants (RFC 8615: the namespace has no index and no
 * fallback representation). Every other unmatched path falls through to static assets.
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
  /**
   * Inbound-Webmention bindings (V-3.1, #359). All optional: a site that hasn't provisioned
   * inbound Webmention has none of them bound, and the `/webmention` route + `queue` consumer
   * degrade gracefully (503 / ack-without-work) rather than throwing. Provisioning wires them —
   * a Cloudflare Queue for async verification, a D1 database for the verified-mention inbox, and
   * the site's canonical origin (the `queue` consumer has no request to derive it from).
   * See `WorkerComposition.generateWranglerToml` (Swift) for the binding generation.
   */
  WEBMENTION_QUEUE?: Queue<WebmentionJob>;
  WEBMENTION_INBOX?: D1Database;
  SITE_URL?: string;
  /**
   * Micropub bindings (V-3.2, #360). Both optional: a site that hasn't provisioned Micropub has
   * neither bound, and `/micropub`/`/media` degrade gracefully (503) rather than throwing.
   * `AUTH_DB`/`TOKEN_SIGNING_KEY` are already required by `IndieAuthEnv` above — Micropub's
   * catalog entry `requires: ["indieauth"]` (resolved by `WorkerActivation`) guarantees both are
   * provisioned together, so this handler still explicitly checks all four before dispatching,
   * matching `handleWebmentionReceive`'s defense-in-depth pattern rather than trusting reachability
   * alone. See `WorkerComposition.generateWranglerToml` (Swift) for the binding generation.
   */
  MICROPUB_DB?: D1Database;
  MEDIA?: R2Bucket;
}

const RATE_LIMIT_WINDOW_SECONDS = 3600;
const RATE_LIMIT_MAX_PER_WINDOW = 5;
const MAX_SUBJECT_LENGTH = 200;
const MAX_FROM_LENGTH = 200;
const MAX_MESSAGE_LENGTH = 10_000;
const MAX_CONSENT_BODY_BYTES = 16_384;
const CONSENT_TTL_SECONDS = 300;
const CONSENT_VERSION = 1;

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

/**
 * Derives a purpose-specific HMAC key from `secret` via HKDF, so that `TOKEN_SIGNING_KEY` — the
 * one secret provisioned for both consent-token signing and owner-password comparison — yields
 * independent subkeys per purpose. A weakness or misuse in one purpose's key can't cross over
 * into the other's.
 */
async function deriveKey(secret: string, purpose: string): Promise<CryptoKey> {
  const baseKey = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    "HKDF",
    false,
    ["deriveKey"],
  );
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: new TextEncoder().encode(purpose) },
    baseKey,
    { name: "HMAC", hash: "SHA-256", length: 256 },
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
  const signature = await crypto.subtle.sign("HMAC", await deriveKey(signingKey, "consent-token"), payload);
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
  if (!(await crypto.subtle.verify("HMAC", await deriveKey(signingKey, "consent-token"), signature, payload))) return false;

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
  const key = await deriveKey(comparisonSecret, "owner-password-compare");
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
  if (!env.SOCIAL_KV) {
    // Fail closed: an unbound KV must never silently disable the limiter.
    console.warn(JSON.stringify({ event: "indieauth.consent_rate_limit_unavailable" }));
    return true;
  }
  const key = await consentRateLimitKey(request);
  const raw = await env.SOCIAL_KV.get(key);
  const count = raw ? Number.parseInt(raw, 10) : 0;
  if (count >= RATE_LIMIT_MAX_PER_WINDOW) return true;
  await env.SOCIAL_KV.put(key, String(count + 1), { expirationTtl: RATE_LIMIT_WINDOW_SECONDS });
  return false;
}

export async function handleIndieAuthConsent(request: Request, env: WorkerEnv): Promise<Response> {
  if (request.method !== "POST") return new Response("Method Not Allowed", { status: 405, headers: { allow: "POST" } });
  if (!env.INDIEAUTH_OWNER_PASSWORD || !env.TOKEN_SIGNING_KEY || !env.SOCIAL_KV) {
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
      try {
        return new URL(resource).origin === baseUrl;
      } catch {
        return false;
      }
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

/**
 * Inbound-Webmention receive endpoint (V-3.1, #359).
 *
 * Composes `@dwk/webmention`'s receiver: a form-encoded `POST` of `source` + `target` is
 * validated synchronously (both `http(s)` URLs, distinct, `target` under this origin) and, on
 * success, enqueued to `WEBMENTION_QUEUE` for asynchronous link-verification before a `202`.
 * The heavy work — fetching the source through an SSRF-safe wrapper and confirming it links to
 * the target — happens in the `queue` consumer, keeping the request path cheap and spam-resistant.
 *
 * Returns `503` when inbound Webmention isn't provisioned for this site (no `WEBMENTION_QUEUE`),
 * so a stray request to an un-provisioned site gets a clean "not configured" rather than the
 * library's loud throw. The `/webmention` route is only advertised (`<link rel="webmention">`)
 * once provisioning is on — that discovery wiring is the paired template/Swift follow-up.
 */
function handleWebmentionReceive(
  request: Request,
  env: WorkerEnv,
  ctx: ExecutionContext,
): Promise<Response> {
  if (!env.WEBMENTION_QUEUE) {
    return Promise.resolve(new Response("Webmention receiving is not configured", { status: 503 }));
  }
  const baseUrl = new URL(request.url).origin;
  const receiver = createWebmention({ baseUrl });
  const webmentionEnv: WebmentionEnv = {
    WEBMENTION_QUEUE: env.WEBMENTION_QUEUE,
    WEBMENTION_INBOX: env.WEBMENTION_INBOX,
  };
  return receiver(request, webmentionEnv, ctx);
}

/**
 * Queue consumer for asynchronous Webmention verification (V-3.1, #359).
 *
 * For each queued `(source, target)` job, `@dwk/webmention` fetches the source through its
 * SSRF-safe wrapper and upserts a verified mention into the D1 inbox — or removes it when the
 * source no longer links. Acks-without-work (rather than throwing) when the inbox or the site
 * origin isn't provisioned, so an un-provisioned site's stray queue delivery can't wedge the
 * consumer. `SITE_URL` scopes which targets verification accepts; the consumer has no request to
 * derive the origin from, so provisioning supplies it as a plain var.
 */
function handleWebmentionQueue(
  batch: MessageBatch<WebmentionJob>,
  env: WorkerEnv,
  ctx: ExecutionContext,
): Promise<void> {
  if (!env.WEBMENTION_QUEUE || !env.WEBMENTION_INBOX || !env.SITE_URL) {
    return Promise.resolve();
  }
  const consumer = createWebmentionQueueConsumer({
    baseUrl: env.SITE_URL,
    inbox: createD1Inbox(env.WEBMENTION_INBOX),
  });
  const webmentionEnv: WebmentionEnv = {
    WEBMENTION_QUEUE: env.WEBMENTION_QUEUE,
    WEBMENTION_INBOX: env.WEBMENTION_INBOX,
  };
  return consumer(batch, webmentionEnv, ctx);
}

/**
 * Micropub server (V-3.2, #360).
 *
 * Composes `@dwk/micropub`'s create/update/delete endpoint and its R2-backed media endpoint.
 * Requires `@dwk/indieauth` to be active on the same site (catalog `requires`, resolved by
 * `WorkerActivation`) — Micropub authorizes every request against `AUTH_DB`'s issued-token store
 * using the same `TOKEN_SIGNING_KEY` IndieAuth signs tokens with.
 *
 * Returns `503` when Micropub isn't fully provisioned (`MICROPUB_DB`/`MEDIA` unbound, or
 * IndieAuth's `AUTH_DB`/`TOKEN_SIGNING_KEY` unbound) rather than letting `@dwk/micropub` throw
 * its own loud startup error.
 */
function handleMicropub(
  request: Request,
  env: WorkerEnv,
  ctx: ExecutionContext,
): Promise<Response> {
  if (!env.MICROPUB_DB || !env.MEDIA || !env.AUTH_DB || !env.TOKEN_SIGNING_KEY) {
    return Promise.resolve(new Response("Micropub is not configured", { status: 503 }));
  }
  const baseUrl = new URL(request.url).origin;
  const micropub = createMicropub({ baseUrl, me: `${baseUrl}/` });
  const micropubEnv: MicropubEnv = {
    MEDIA: env.MEDIA,
    MICROPUB_DB: env.MICROPUB_DB,
    AUTH_DB: env.AUTH_DB,
    TOKEN_SIGNING_KEY: env.TOKEN_SIGNING_KEY,
  };
  return micropub(request, micropubEnv, ctx);
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

/** One dynamic route this Worker serves — the handler-side mirror of a catalog route claim. */
export interface WorkerRoute {
  /** Absolute claimed path, e.g. `"/.well-known/oauth-authorization-server"`. */
  path: string;
  /** `exact` matches only `path`; `prefix` additionally matches `path` + `/…` descendants. */
  match: "exact" | "prefix";
  /** Declared methods. HEAD is served only when listed alongside GET — the dispatcher mirrors
   *  GET's status/headers without a body and never hands handlers a raw HEAD request (catalog
   *  claims enforce the same GET pairing app-side). */
  methods: readonly string[];
  handler: (request: Request, env: WorkerEnv, ctx: ExecutionContext) => Promise<Response> | Response;
}

export const ROUTES: readonly WorkerRoute[] = [
  {
    // RFC 8414 authorization-server metadata (linked via rel=indieauth-metadata in BaseLayout).
    path: "/.well-known/oauth-authorization-server",
    match: "exact",
    methods: ["GET", "HEAD"],
    handler: (request, env, ctx) => indieAuthHandler(request, env)(request, env, ctx),
  },
  {
    // GET renders/redirects the authorization request; POST redeems an authorization code for
    // profile information (IndieAuth authorization-endpoint code exchange).
    path: "/authorize",
    match: "exact",
    methods: ["GET", "POST"],
    handler: (request, env, ctx) => indieAuthHandler(request, env)(request, env, ctx),
  },
  {
    // POST is the token grant; GET is IndieAuth token-endpoint access-token verification.
    path: "/token",
    match: "exact",
    methods: ["GET", "POST"],
    handler: (request, env, ctx) => indieAuthHandler(request, env)(request, env, ctx),
  },
  {
    path: "/revocation",
    match: "exact",
    methods: ["POST"],
    handler: (request, env, ctx) => indieAuthHandler(request, env)(request, env, ctx),
  },
  {
    path: "/indieauth/consent",
    match: "exact",
    methods: ["POST"],
    handler: (request, env) => handleIndieAuthConsent(request, env),
  },
  {
    path: "/inbox",
    match: "exact",
    methods: ["POST"],
    handler: (request, env) => handleInbox(request, env),
  },
  {
    // Inbound Webmention receiver (V-3.1, #359): POST source+target, validate, enqueue, 202.
    path: "/webmention",
    match: "exact",
    methods: ["POST"],
    handler: (request, env, ctx) => handleWebmentionReceive(request, env, ctx),
  },
  {
    // Micropub create/update/delete + q=config/q=source/q=syndicate-to queries (V-3.2, #360).
    path: "/micropub",
    match: "exact",
    methods: ["GET", "POST"],
    handler: (request, env, ctx) => handleMicropub(request, env, ctx),
  },
  {
    // Media endpoint upload (V-3.2, #360). GET-on-bare-/media is not served (matches
    // @dwk/micropub's default extensions.proposed: false — GET is only the media *retrieval*
    // path below, under /media/<key>, not the collection root).
    path: "/media",
    match: "exact",
    methods: ["POST"],
    handler: (request, env, ctx) => handleMicropub(request, env, ctx),
  },
  {
    // Media retrieval by key (V-3.2, #360). NOTE: the catalog.json claim for this prefix route
    // currently has no specificationURL, which WorkerRouteClaims.validate (Swift) requires for
    // any prefix claim — until that's patched upstream, this route is unreachable in production
    // (no run_worker_first entry gets generated for it), though it's still exercised directly by
    // the miniflare test suite below.
    path: "/media",
    match: "prefix",
    methods: ["GET", "HEAD"],
    handler: (request, env, ctx) => handleMicropub(request, env, ctx),
  },
];

export function matchRoute(pathname: string, routes: readonly WorkerRoute[] = ROUTES): WorkerRoute | null {
  for (const route of routes) {
    if (pathname === route.path) return route;
    if (route.match === "prefix" && pathname.startsWith(`${route.path}/`)) return route;
  }
  return null;
}

/** A protocol-grade 404: correct status, no HTML error page, nothing for a client to mis-parse. */
function notFound(): Response {
  return new Response("Not Found", {
    status: 404,
    headers: { "content-type": "text/plain; charset=utf-8", "x-content-type-options": "nosniff" },
  });
}

/** True for the bare `/.well-known` directory and anything under it, case-insensitively — the
 *  case fold exists so `/.Well-Known/...` variants get the namespace's true-404 policy instead
 *  of leaking to an HTML asset 404 (claimed routes themselves match case-sensitively). */
function isWellKnownNamespace(pathname: string): boolean {
  const lower = pathname.toLowerCase();
  return lower === "/.well-known" || lower === "/.well-known/" || lower.startsWith("/.well-known/");
}

export default {
  async fetch(request: Request, env: WorkerEnv, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const pathname = url.pathname;

    // Malformed percent-encoding can't name any claimed route or asset; answer plainly instead
    // of handing it to an HTML 404 page.
    let decoded: string | null;
    try {
      decoded = decodeURIComponent(pathname);
    } catch {
      decoded = null;
    }
    if (decoded === null) {
      return notFound();
    }

    const route = matchRoute(pathname);
    if (route) {
      const mirrorsGet = request.method === "HEAD" && route.methods.includes("HEAD") && route.methods.includes("GET");
      if (mirrorsGet) {
        // Query string rides along in `request.url`; only the method changes.
        const getResponse = await route.handler(
          new Request(request.url, { method: "GET", headers: request.headers }),
          env,
          ctx,
        );
        return new Response(null, {
          status: getResponse.status,
          statusText: getResponse.statusText,
          headers: getResponse.headers,
        });
      }
      if (!route.methods.includes(request.method)) {
        return new Response("Method Not Allowed", {
          status: 405,
          headers: { allow: route.methods.join(", "), "content-type": "text/plain; charset=utf-8" },
        });
      }
      return route.handler(request, env, ctx);
    }

    // Unclaimed well-known names, the bare directory, and case/trailing-slash or encoded
    // variants (checked post-decode so `/%2Ewell-known/...` can't slip past) return a true 404
    // rather than falling through to an HTML asset 404. Genuinely static well-known files (e.g.
    // security.txt) are served asset-first and never reach this Worker.
    if (isWellKnownNamespace(pathname) || isWellKnownNamespace(decoded)) {
      return notFound();
    }

    const assets = env.ASSETS;
    if (!assets) {
      return new Response("No assets binding configured", { status: 500 });
    }
    return assets.fetch(request);
  },

  // Async Webmention verification (V-3.1, #359). Present unconditionally; no-ops for sites
  // without inbound Webmention provisioned (see `handleWebmentionQueue`).
  async queue(batch: MessageBatch<WebmentionJob>, env: WorkerEnv, ctx: ExecutionContext): Promise<void> {
    return handleWebmentionQueue(batch, env, ctx);
  },
} satisfies ExportedHandler<WorkerEnv, WebmentionJob>;
