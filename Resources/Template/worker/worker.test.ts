import { env } from "cloudflare:workers";
import { createExecutionContext } from "cloudflare:test";
import { createIndieAuthStore, type AuthorizationRequest } from "@dwk/indieauth";
import { beforeEach, expect, test } from "vitest";
import {
  validateInboxFields,
  isRateLimited,
  handleInbox,
  handleIndieAuthConsent,
  createConsentToken,
  verifyConsentToken,
  type InboxKV,
  type WorkerEnv,
} from "./worker";
import worker from "./worker";

const testEnv = env as unknown as WorkerEnv;

beforeEach(async () => {
  await createIndieAuthStore(testEnv).init();
});

function makeFakeKV(initial: Record<string, string> = {}): InboxKV & { store: Map<string, string> } {
  const store = new Map(Object.entries(initial));
  return {
    store,
    async get(key: string) {
      return store.has(key) ? store.get(key)! : null;
    },
    async put(key: string, value: string) {
      store.set(key, value);
    },
  };
}

test("validateInboxFields: trims and accepts complete fields", () => {
  const result = validateInboxFields({ subject: " Hello ", from: " a@example.com ", message: " hi " });
  expect(result).toEqual({ subject: "Hello", from: "a@example.com", message: "hi" });
});

test("validateInboxFields: rejects a missing field", () => {
  expect(validateInboxFields({ subject: "Hello", from: "a@example.com", message: "" })).toBeNull();
});

test("validateInboxFields: rejects an over-long field", () => {
  expect(
    validateInboxFields({ subject: "x".repeat(201), from: "a@example.com", message: "hi" }),
  ).toBeNull();
});

test("isRateLimited: allows up to the window max, then blocks", async () => {
  const kv = makeFakeKV();
  for (let i = 0; i < 5; i++) {
    expect(await isRateLimited(kv, "1.2.3.4")).toBe(false);
  }
  expect(await isRateLimited(kv, "1.2.3.4")).toBe(true);
});

test("isRateLimited: tracks separate IPs independently", async () => {
  const kv = makeFakeKV();
  for (let i = 0; i < 5; i++) await isRateLimited(kv, "1.2.3.4");
  expect(await isRateLimited(kv, "5.6.7.8")).toBe(false);
});

test("handleInbox: stages a valid JSON submission and returns 202", async () => {
  const kv = makeFakeKV();
  const request = new Request("https://example.com/inbox", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ subject: "Hello", from: "a@example.com", message: "Hi there" }),
  });
  const response = await handleInbox(request, { INBOX_KV: kv });
  expect(response.status).toBe(202);
  // 2 keys, not 1: isRateLimited() always writes a `ratelimit:<ip>` counter as a side effect on
  // every allowed call, in addition to the `inbox:<id>` staged submission written here.
  expect(kv.store.size).toBe(2);
  const [, stagedRaw] = [...kv.store.entries()].find(([key]) => key.startsWith("inbox:"))!;
  const staged = JSON.parse(stagedRaw);
  expect(staged.subject).toBe("Hello");
  expect(staged.from).toBe("a@example.com");
  expect(staged.message).toBe("Hi there");
  expect(typeof staged.id).toBe("string");
  expect(typeof staged.receivedAt).toBe("string");
});

test("handleInbox: silently drops a honeypot-tripped submission", async () => {
  const kv = makeFakeKV();
  const request = new Request("https://example.com/inbox", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      subject: "Hello", from: "a@example.com", message: "Hi", website: "http://spam.example",
    }),
  });
  const response = await handleInbox(request, { INBOX_KV: kv });
  expect(response.status).toBe(202);
  // 1 key, not 0: rate limiting runs before the honeypot check in handleInbox, so this call still
  // writes the `ratelimit:<ip>` counter — a honeypot-tripped request still consumes a rate-limit
  // slot, which is correct: bots shouldn't be exempt from rate limiting just because they tripped
  // the honeypot.
  expect(kv.store.size).toBe(1);
});

test("handleInbox: rejects a non-POST method", async () => {
  const kv = makeFakeKV();
  const request = new Request("https://example.com/inbox", { method: "GET" });
  const response = await handleInbox(request, { INBOX_KV: kv });
  expect(response.status).toBe(405);
});

test("handleInbox: 429s once the per-IP rate limit is exceeded", async () => {
  const kv = makeFakeKV();
  const makeRequest = () =>
    new Request("https://example.com/inbox", {
      method: "POST",
      headers: { "content-type": "application/json", "CF-Connecting-IP": "1.2.3.4" },
      body: JSON.stringify({ subject: "Hello", from: "a@example.com", message: "Hi" }),
    });
  for (let i = 0; i < 5; i++) {
    const response = await handleInbox(makeRequest(), { INBOX_KV: kv });
    expect(response.status).toBe(202);
  }
  const limited = await handleInbox(makeRequest(), { INBOX_KV: kv });
  expect(limited.status).toBe(429);
});

test("handleInbox: 500s when INBOX_KV isn't bound", async () => {
  const request = new Request("https://example.com/inbox", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ subject: "Hello", from: "a@example.com", message: "Hi" }),
  });
  const response = await handleInbox(request, {});
  expect(response.status).toBe(500);
});

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function pkceChallenge(verifier: string): Promise<string> {
  return base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))));
}

async function dpopProof(url: string): Promise<string> {
  const keyPair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const jwk = await crypto.subtle.exportKey("jwk", keyPair.publicKey);
  const header = base64url(new TextEncoder().encode(JSON.stringify({ typ: "dpop+jwt", alg: "ES256", jwk })));
  const payload = base64url(new TextEncoder().encode(JSON.stringify({
    jti: crypto.randomUUID(),
    htm: "POST",
    htu: url,
    iat: Math.floor(Date.now() / 1000),
  })));
  const signingInput = new TextEncoder().encode(`${header}.${payload}`);
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, keyPair.privateKey, signingInput);
  return `${header}.${payload}.${base64url(new Uint8Array(signature))}`;
}

async function fetchWorker(request: Request): Promise<Response> {
  return worker.fetch(request, testEnv, createExecutionContext());
}

test("IndieAuth metadata advertises the authorization and token endpoints", async () => {
  const response = await fetchWorker(new Request("https://owner.example/.well-known/oauth-authorization-server"));
  expect(response.status).toBe(200);
  await expect(response.json()).resolves.toMatchObject({
    issuer: "https://owner.example",
    authorization_endpoint: "https://owner.example/authorize",
    token_endpoint: "https://owner.example/token",
    code_challenge_methods_supported: ["S256"],
  });
});

test("IndieAuth owner consent completes PKCE sign-in and issues a DPoP token", async () => {
  const verifier = "anglesite-indieauth-verifier-with-more-than-forty-three-characters";
  const challenge = await pkceChallenge(verifier);
  const authorize = new URL("https://owner.example/authorize");
  authorize.search = new URLSearchParams({
    client_id: "https://client.example/app",
    redirect_uri: "https://client.example/callback",
    response_type: "code",
    state: "state-355",
    code_challenge: challenge,
    code_challenge_method: "S256",
    scope: "create update",
  }).toString();

  const prompt = await fetchWorker(new Request(authorize));
  expect(prompt.status).toBe(200);
  expect(await prompt.text()).toContain("Approve sign-in");

  const consentForm = new URLSearchParams(authorize.search);
  consentForm.set("password", "correct horse battery staple");
  const consent = await fetchWorker(new Request("https://owner.example/indieauth/consent", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "CF-Connecting-IP": "192.0.2.35" },
    body: consentForm,
  }));
  expect(consent.status).toBe(303);
  const approvedURL = new URL(consent.headers.get("location")!);
  expect(approvedURL.pathname).toBe("/authorize");
  expect(approvedURL.searchParams.get("consent")).toBeTruthy();

  const approval = await fetchWorker(new Request(approvedURL));
  expect(approval.status).toBe(302);
  const clientCallback = new URL(approval.headers.get("location")!);
  expect(clientCallback.origin).toBe("https://client.example");
  expect(clientCallback.searchParams.get("state")).toBe("state-355");
  const code = clientCallback.searchParams.get("code");
  expect(code).toBeTruthy();

  const tokenURL = "https://owner.example/token";
  const token = await fetchWorker(new Request(tokenURL, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      DPoP: await dpopProof(tokenURL),
    },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code: code!,
      client_id: "https://client.example/app",
      redirect_uri: "https://client.example/callback",
      code_verifier: verifier,
    }),
  }));
  expect(token.status).toBe(200);
  await expect(token.json()).resolves.toMatchObject({
    token_type: "DPoP",
    scope: "create update",
    me: "https://owner.example/",
  });
});

test("IndieAuth consent rejects the wrong owner password", async () => {
  const body = new URLSearchParams({
    client_id: "https://client.example/app",
    redirect_uri: "https://client.example/callback",
    response_type: "code",
    state: "wrong-password",
    code_challenge: "challenge",
    code_challenge_method: "S256",
    scope: "create",
    password: "incorrect",
  });
  const response = await fetchWorker(new Request("https://owner.example/indieauth/consent", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "CF-Connecting-IP": "192.0.2.36" },
    body,
  }));
  expect(response.status).toBe(401);
});

function sampleAuthorizationRequest(overrides: Partial<AuthorizationRequest> = {}): AuthorizationRequest {
  return {
    clientId: "https://client.example/app",
    redirectUri: "https://client.example/callback",
    state: "state-355",
    codeChallenge: "challenge",
    codeChallengeMethod: "S256",
    scope: "create",
    scopes: ["create"],
    ...overrides,
  };
}

test("verifyConsentToken: accepts a token replayed against the exact request it was issued for", async () => {
  const request = sampleAuthorizationRequest();
  const token = await createConsentToken(request, "test-signing-key");
  expect(await verifyConsentToken(token, request, "test-signing-key")).toBe(true);
});

test("verifyConsentToken: rejects a token replayed against a different client_id", async () => {
  const granted = sampleAuthorizationRequest();
  const token = await createConsentToken(granted, "test-signing-key");
  const tampered = sampleAuthorizationRequest({ clientId: "https://attacker.example/app" });
  expect(await verifyConsentToken(token, tampered, "test-signing-key")).toBe(false);
});

test("verifyConsentToken: rejects a token replayed against a different redirect_uri", async () => {
  const granted = sampleAuthorizationRequest();
  const token = await createConsentToken(granted, "test-signing-key");
  const tampered = sampleAuthorizationRequest({ redirectUri: "https://attacker.example/callback" });
  expect(await verifyConsentToken(token, tampered, "test-signing-key")).toBe(false);
});

test("verifyConsentToken: rejects a token replayed with an escalated scope", async () => {
  const granted = sampleAuthorizationRequest();
  const token = await createConsentToken(granted, "test-signing-key");
  const tampered = sampleAuthorizationRequest({ scope: "create update delete", scopes: ["create", "update", "delete"] });
  expect(await verifyConsentToken(token, tampered, "test-signing-key")).toBe(false);
});

test("verifyConsentToken: rejects a token signed with a different key", async () => {
  const request = sampleAuthorizationRequest();
  const token = await createConsentToken(request, "test-signing-key");
  expect(await verifyConsentToken(token, request, "a-different-signing-key")).toBe(false);
});

test("verifyConsentToken: rejects an expired token", async () => {
  const request = sampleAuthorizationRequest();
  const issuedAt = 1_000;
  const token = await createConsentToken(request, "test-signing-key", issuedAt);
  expect(await verifyConsentToken(token, request, "test-signing-key", issuedAt + 301)).toBe(false);
});

test("handleIndieAuthConsent: 503s when a required secret isn't configured", async () => {
  const { TOKEN_SIGNING_KEY: _unusedSigningKey, ...envWithoutSigningKey } = testEnv;
  const request = new Request("https://owner.example/indieauth/consent", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "CF-Connecting-IP": "192.0.2.40" },
    body: new URLSearchParams({ password: "correct horse battery staple" }),
  });
  const response = await handleIndieAuthConsent(request, envWithoutSigningKey as unknown as WorkerEnv);
  expect(response.status).toBe(503);
});

test("handleIndieAuthConsent: 503s when the rate-limit KV isn't bound (fails closed, not open)", async () => {
  const { SOCIAL_KV: _unusedSocialKV, ...envWithoutKV } = testEnv;
  const request = new Request("https://owner.example/indieauth/consent", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "CF-Connecting-IP": "192.0.2.42" },
    body: new URLSearchParams({ password: "correct horse battery staple" }),
  });
  const response = await handleIndieAuthConsent(request, envWithoutKV as unknown as WorkerEnv);
  expect(response.status).toBe(503);
});

test("handleIndieAuthConsent: 400s on a malformed (oversized) form body", async () => {
  const request = new Request("https://owner.example/indieauth/consent", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "CF-Connecting-IP": "192.0.2.41" },
    body: `password=${"x".repeat(20_000)}`,
  });
  const response = await handleIndieAuthConsent(request, testEnv);
  expect(response.status).toBe(400);
});

test("handleIndieAuthConsent: 429s once the per-IP login attempt limit is exceeded", async () => {
  const makeRequest = () =>
    new Request("https://owner.example/indieauth/consent", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", "CF-Connecting-IP": "192.0.2.43" },
      body: new URLSearchParams({ password: "incorrect" }),
    });
  for (let i = 0; i < 5; i++) {
    const response = await handleIndieAuthConsent(makeRequest(), testEnv);
    expect(response.status).toBe(401);
  }
  const limited = await handleIndieAuthConsent(makeRequest(), testEnv);
  expect(limited.status).toBe(429);
});
