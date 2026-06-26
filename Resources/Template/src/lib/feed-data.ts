import { getCollection } from "astro:content";
import { FEED_COLLECTIONS, toFeedItem, sortAndLimit, type FeedItem } from "./feeds.ts";

const PER_COLLECTION_LIMIT = 50;
const COMBINED_LIMIT = 50;

/// Map a collection's entries to feed items *without* sorting — callers that immediately re-sort
/// (the combined feed) skip the wasted per-collection sort.
async function mapCollection(collection: string, site: string): Promise<FeedItem[]> {
  const entries = await getCollection(collection as any);
  return entries.map((e: any) =>
    toFeedItem(collection, { id: e.id, collection, data: e.data, body: e.body }, site),
  );
}

export async function getCollectionItems(
  collection: string,
  site: string,
  limit = PER_COLLECTION_LIMIT,
): Promise<FeedItem[]> {
  return sortAndLimit(await mapCollection(collection, site), limit);
}

export async function getCombinedItems(site: string, limit = COMBINED_LIMIT): Promise<FeedItem[]> {
  const all: FeedItem[] = [];
  for (const collection of Object.keys(FEED_COLLECTIONS)) {
    all.push(...(await mapCollection(collection, site)));
  }
  return sortAndLimit(all, limit);
}
