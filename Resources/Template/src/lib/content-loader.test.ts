import test from "node:test";
import assert from "node:assert/strict";
import { createContentAPILoader } from "./content-loader";

function fakeContext(overrides: Partial<Record<string, unknown>> = {}) {
  const stored: Array<{ id: string; data: unknown; digest?: string }> = [];
  return {
    stored,
    context: {
      store: {
        clear: () => { stored.length = 0; },
        set: (entry: { id: string; data: unknown; digest?: string }) => { stored.push(entry); },
      },
      parseData: async ({ id, data }: { id: string; data: unknown }) => data,
      generateDigest: (data: unknown) => JSON.stringify(data),
      logger: { info: () => {}, warn: () => {}, error: () => {} },
      config: {},
      ...overrides,
    },
  };
}

test("loads entries from a paginated content API into the store", async () => {
  const fetchCalls: string[] = [];
  const fakeFetch = async (url: string) => {
    fetchCalls.push(url);
    if (url.includes("cursor=")) {
      return new Response(JSON.stringify({ items: [], nextCursor: null }), { status: 200 });
    }
    return new Response(
      JSON.stringify({
        items: [{ id: "hello-world", title: "Hello World", pubDate: "2026-07-18", draft: false }],
        nextCursor: null,
      }),
      { status: 200 },
    );
  };

  const loader = createContentAPILoader("blog", { apiURL: "https://example.workers.dev/api", fetchImpl: fakeFetch });
  const { context, stored } = fakeContext();
  await loader.load(context as any);

  assert.equal(stored.length, 1);
  assert.equal(stored[0].id, "hello-world");
  assert.equal((stored[0].data as { title: string }).title, "Hello World");
});

test("follows the cursor across multiple pages", async () => {
  const pages: Record<string, unknown> = {
    "https://example.workers.dev/api/blog?": {
      items: [{ id: "post-1", title: "Post 1", pubDate: "2026-07-01", draft: false }],
      nextCursor: "page-2",
    },
    "https://example.workers.dev/api/blog?cursor=page-2": {
      items: [{ id: "post-2", title: "Post 2", pubDate: "2026-07-02", draft: false }],
      nextCursor: null,
    },
  };
  const fakeFetch = async (url: string) => {
    const body = pages[url];
    if (!body) throw new Error(`unexpected URL: ${url}`);
    return new Response(JSON.stringify(body), { status: 200 });
  };

  const loader = createContentAPILoader("blog", { apiURL: "https://example.workers.dev/api", fetchImpl: fakeFetch });
  const { context, stored } = fakeContext();
  await loader.load(context as any);

  assert.equal(stored.length, 2);
  assert.deepEqual(stored.map((e) => e.id).sort(), ["post-1", "post-2"]);
});

test("draft entries are filtered server-side but the loader doesn't crash if one leaks through", async () => {
  const fakeFetch = async () =>
    new Response(
      JSON.stringify({
        items: [
          { id: "published", title: "Published", pubDate: "2026-07-18", draft: false },
          { id: "still-draft", title: "Still Draft", pubDate: "2026-07-18", draft: true },
        ],
        nextCursor: null,
      }),
      { status: 200 },
    );

  const loader = createContentAPILoader("blog", { apiURL: "https://example.workers.dev/api", fetchImpl: fakeFetch });
  const { context, stored } = fakeContext();
  await loader.load(context as any);

  // The loader itself doesn't filter drafts (the Worker's bulk-read endpoint is draft-filtered
  // server-side per §C.4) — it stores whatever it's handed, same as glob() stores every file it
  // finds. Draft filtering for rendering is the collection consumer's job, unchanged from today.
  assert.equal(stored.length, 2);
});

test("a non-2xx response fails the build loudly instead of yielding an empty collection", async () => {
  const fakeFetch = async () => new Response("service unavailable", { status: 503 });
  const loader = createContentAPILoader("blog", { apiURL: "https://example.workers.dev/api", fetchImpl: fakeFetch });
  const { context } = fakeContext();

  await assert.rejects(() => loader.load(context as any), /CMS content API unreachable.*503/s);
});

test("a network failure fails the build loudly", async () => {
  const fakeFetch = async () => { throw new Error("getaddrinfo ENOTFOUND"); };
  const loader = createContentAPILoader("blog", { apiURL: "https://example.workers.dev/api", fetchImpl: fakeFetch });
  const { context } = fakeContext();

  await assert.rejects(() => loader.load(context as any), /CMS content API unreachable/);
});
