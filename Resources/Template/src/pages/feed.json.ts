import type { APIContext } from "astro";
import { getCombinedItems } from "../lib/feed-data.ts";
import { renderJsonFeed, siteFrom } from "../lib/feeds.ts";

export async function GET(context: APIContext) {
  const site = siteFrom(context);
  return renderJsonFeed({
    title: "All posts",
    site,
    feedUrl: new URL("/feed.json", site).href,
    items: await getCombinedItems(site),
  });
}
