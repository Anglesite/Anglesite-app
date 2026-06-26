import type { APIContext } from "astro";
import { getCollectionItems } from "../../lib/feed-data.ts";
import { renderRss, FEED_COLLECTIONS } from "../../lib/feeds.ts";

const COLLECTION = "albums";

export async function GET(context: APIContext) {
  const site = context.site!.href;
  return renderRss({
    title: FEED_COLLECTIONS[COLLECTION].title,
    description: `${FEED_COLLECTIONS[COLLECTION].title} feed`,
    site,
    items: await getCollectionItems(COLLECTION, site),
  });
}
