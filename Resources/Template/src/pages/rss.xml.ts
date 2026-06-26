import type { APIContext } from "astro";
import { getCombinedItems } from "../lib/feed-data.ts";
import { renderRss } from "../lib/feeds.ts";

export async function GET(context: APIContext) {
  const site = context.site!.href;
  return renderRss({
    title: "All posts",
    description: "Everything published on this site.",
    site,
    items: await getCombinedItems(site),
  });
}
