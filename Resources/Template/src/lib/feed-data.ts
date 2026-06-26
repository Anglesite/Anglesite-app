import { getCollection } from "astro:content";
import { FEED_COLLECTIONS, toFeedItem, sortAndLimit, type FeedItem } from "./feeds.ts";

const COMBINED_LIMIT = 50;

export async function getCollectionItems(collection: string, site: string): Promise<FeedItem[]> {
  const entries = await getCollection(collection as any);
  const items = entries.map((e: any) =>
    toFeedItem(collection, { id: e.id, collection, data: e.data, body: e.body }, site),
  );
  return sortAndLimit(items);
}

export async function getCombinedItems(site: string, limit = COMBINED_LIMIT): Promise<FeedItem[]> {
  const all: FeedItem[] = [];
  for (const collection of Object.keys(FEED_COLLECTIONS)) {
    all.push(...(await getCollectionItems(collection, site)));
  }
  return sortAndLimit(all, limit);
}
