import type { APIContext } from "astro";
import { getCollectionItems } from "../../lib/feed-data.ts";
import { renderAtom, FEED_COLLECTIONS } from "../../lib/feeds.ts";

const COLLECTION = "likes";

export async function GET(context: APIContext) {
  const site = context.site!.href;
  return renderAtom({
    title: FEED_COLLECTIONS[COLLECTION].title,
    site,
    feedUrl: new URL(`/${COLLECTION}/atom.xml`, site).href,
    items: await getCollectionItems(COLLECTION, site),
  });
}
