import type { Loader, LoaderContext } from "astro/loaders";

/** One page of the Worker's bulk content-read endpoint (§C.4 of the publishing design). */
interface ContentAPIPage {
  items: Array<{ id: string; [key: string]: unknown }>;
  nextCursor: string | null;
}

export interface ContentAPILoaderOptions {
  /** Base URL of the site's per-site Worker content API, e.g. `https://example.workers.dev/api`. */
  apiURL: string;
  /**
   * Injectable for tests; defaults to the global `fetch`. Narrowed to the single-string-URL shape
   * the loader actually calls (rather than `typeof fetch`) so a plain `(url: string) =>
   * Promise<Response>` fake satisfies it without fighting the ambient `@cloudflare/workers-types`
   * `fetch` overloads, which require `URL | RequestInfo`.
   */
  fetchImpl?: (url: string) => Promise<Response>;
}

/**
 * A Content Layer `Loader` that reads a collection's entries from the per-site Worker's bulk
 * content-read endpoint instead of the filesystem — the CMS-mode counterpart to `glob()`
 * (#799, groundwork for slice 4's CMS mode, spec §C.4). Selected in `content.config.ts` only
 * when `.site-config`'s `CMS_CONTENT_API_URL` is set; un-provisioned sites keep `glob()`
 * unchanged. The same zod schema validates entries from either loader via Astro's `parseData`.
 *
 * Draft filtering happens server-side (the bulk endpoint is documented as "draft-filtered
 * server-side" per §C.4) — this loader stores whatever the API returns, same as `glob()` stores
 * every file it finds regardless of a `draft: true` frontmatter field.
 *
 * A non-2xx response or a network failure throws (not returns empty) — "CMS-unreachable fails
 * the build loudly," per the issue's explicit contract, so a Worker outage can never silently
 * ship a site with an empty blog instead of failing the build.
 */
export function createContentAPILoader(collectionName: string, options: ContentAPILoaderOptions): Loader {
  const fetchImpl: (url: string) => Promise<Response> = options.fetchImpl ?? ((url) => fetch(url));
  const baseURL = options.apiURL.endsWith("/") ? options.apiURL.slice(0, -1) : options.apiURL;

  return {
    name: `content-api:${collectionName}`,
    load: async ({ store, parseData, generateDigest, logger }: LoaderContext) => {
      store.clear();
      let cursor: string | null = null;
      let pageCount = 0;

      do {
        const url = cursor
          ? `${baseURL}/${collectionName}?cursor=${encodeURIComponent(cursor)}`
          : `${baseURL}/${collectionName}?`;

        let response: Response;
        try {
          response = await fetchImpl(url);
        } catch (error) {
          throw new Error(`CMS content API unreachable for "${collectionName}" — ${String(error)}`);
        }
        if (!response.ok) {
          throw new Error(
            `CMS content API unreachable for "${collectionName}" — ${url} returned ${response.status}`,
          );
        }

        const page = (await response.json()) as ContentAPIPage;
        for (const item of page.items) {
          const { id, ...data } = item;
          const parsed = await parseData({ id, data });
          const digest = generateDigest(parsed);
          store.set({ id, data: parsed, digest });
        }

        cursor = page.nextCursor;
        pageCount += 1;
        if (pageCount > 1000) {
          // Belt-and-suspenders against a misbehaving endpoint that never returns a null cursor.
          throw new Error(`CMS content API for "${collectionName}" did not terminate after 1000 pages`);
        }
      } while (cursor !== null);

      logger.info(`content-api:${collectionName}: loaded ${pageCount} page(s)`);
    },
  };
}
