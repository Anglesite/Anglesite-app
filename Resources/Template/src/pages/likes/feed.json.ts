import type { APIContext } from "astro";
import { getCollectionItems } from "../../lib/feed-data.ts";
import { renderJsonFeed, FEED_COLLECTIONS } from "../../lib/feeds.ts";

const COLLECTION = "likes";

export async function GET(context: APIContext) {
  const site = context.site!.href;
  return renderJsonFeed({
    title: FEED_COLLECTIONS[COLLECTION].title,
    site,
    feedUrl: new URL(`/${COLLECTION}/feed.json`, site).href,
    items: await getCollectionItems(COLLECTION, site),
  });
}
