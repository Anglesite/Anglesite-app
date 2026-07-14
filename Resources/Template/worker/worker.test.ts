import test from "node:test";
import assert from "node:assert/strict";
import { validateInboxFields, isRateLimited, handleInbox, type InboxKV } from "./worker";

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
  assert.deepEqual(result, { subject: "Hello", from: "a@example.com", message: "hi" });
});

test("validateInboxFields: rejects a missing field", () => {
  assert.equal(validateInboxFields({ subject: "Hello", from: "a@example.com", message: "" }), null);
});

test("validateInboxFields: rejects an over-long field", () => {
  assert.equal(
    validateInboxFields({ subject: "x".repeat(201), from: "a@example.com", message: "hi" }),
    null
  );
});

test("isRateLimited: allows up to the window max, then blocks", async () => {
  const kv = makeFakeKV();
  for (let i = 0; i < 5; i++) {
    assert.equal(await isRateLimited(kv, "1.2.3.4"), false);
  }
  assert.equal(await isRateLimited(kv, "1.2.3.4"), true);
});

test("isRateLimited: tracks separate IPs independently", async () => {
  const kv = makeFakeKV();
  for (let i = 0; i < 5; i++) await isRateLimited(kv, "1.2.3.4");
  assert.equal(await isRateLimited(kv, "5.6.7.8"), false);
});

test("handleInbox: stages a valid JSON submission and returns 202", async () => {
  const kv = makeFakeKV();
  const request = new Request("https://example.com/inbox", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ subject: "Hello", from: "a@example.com", message: "Hi there" }),
  });
  const response = await handleInbox(request, { INBOX_KV: kv });
  assert.equal(response.status, 202);
  // 2 keys, not 1: isRateLimited() always writes a `ratelimit:<ip>` counter as a side effect on
  // every allowed call, in addition to the `inbox:<id>` staged submission written here.
  assert.equal(kv.store.size, 2);
  const [, stagedRaw] = [...kv.store.entries()].find(([key]) => key.startsWith("inbox:"))!;
  const staged = JSON.parse(stagedRaw);
  assert.equal(staged.subject, "Hello");
  assert.equal(staged.from, "a@example.com");
  assert.equal(staged.message, "Hi there");
  assert.equal(typeof staged.id, "string");
  assert.equal(typeof staged.receivedAt, "string");
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
  assert.equal(response.status, 202);
  // 1 key, not 0: rate limiting runs before the honeypot check in handleInbox, so this call still
  // writes the `ratelimit:<ip>` counter — a honeypot-tripped request still consumes a rate-limit
  // slot, which is correct: bots shouldn't be exempt from rate limiting just because they tripped
  // the honeypot.
  assert.equal(kv.store.size, 1);
});

test("handleInbox: rejects a non-POST method", async () => {
  const kv = makeFakeKV();
  const request = new Request("https://example.com/inbox", { method: "GET" });
  const response = await handleInbox(request, { INBOX_KV: kv });
  assert.equal(response.status, 405);
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
    assert.equal(response.status, 202);
  }
  const limited = await handleInbox(makeRequest(), { INBOX_KV: kv });
  assert.equal(limited.status, 429);
});

test("handleInbox: 500s when INBOX_KV isn't bound", async () => {
  const request = new Request("https://example.com/inbox", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ subject: "Hello", from: "a@example.com", message: "Hi" }),
  });
  const response = await handleInbox(request, {});
  assert.equal(response.status, 500);
});
