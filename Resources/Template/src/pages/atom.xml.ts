import type { APIContext } from "astro";
import { getCombinedItems } from "../lib/feed-data.ts";
import { renderAtom } from "../lib/feeds.ts";

export async function GET(context: APIContext) {
  const site = context.site!.href;
  return renderAtom({
    title: "All posts",
    site,
    feedUrl: new URL("/atom.xml", site).href,
    items: await getCombinedItems(site),
  });
}
