import rss from "@astrojs/rss";

export interface FeedItem {
  title: string;
  link: string; // absolute
  date: Date;
  summary: string;
}

export type FeedEntry = {
  id: string;
  collection: string;
  data: Record<string, any>;
  body?: string;
};

export interface FeedCollectionConfig {
  title: string;
  dateField: string;
  deriveTitle(entry: FeedEntry): string;
}

function host(url: unknown): string {
  try {
    return new URL(String(url)).host;
  } catch {
    return String(url ?? "");
  }
}

function excerpt(body: string | undefined, max = 80): string {
  const text = (body ?? "").replace(/\s+/g, " ").trim();
  if (text.length <= max) return text || "Untitled";
  return text.slice(0, max).trimEnd() + "…";
}

export const FEED_COLLECTIONS: Record<string, FeedCollectionConfig> = {
  blog: { title: "Blog", dateField: "pubDate", deriveTitle: (e) => e.data.title },
  notes: { title: "Notes", dateField: "publishDate", deriveTitle: (e) => excerpt(e.body) },
  articles: { title: "Articles", dateField: "publishDate", deriveTitle: (e) => e.data.title },
  photos: {
    title: "Photos",
    dateField: "publishDate",
    deriveTitle: (e) => e.data.caption ?? "Photo",
  },
  albums: { title: "Albums", dateField: "publishDate", deriveTitle: (e) => e.data.title },
  bookmarks: {
    title: "Bookmarks",
    dateField: "publishDate",
    deriveTitle: (e) => e.data.title ?? host(e.data.bookmarkOf),
  },
  replies: {
    title: "Replies",
    dateField: "publishDate",
    deriveTitle: (e) => "Re: " + host(e.data.inReplyTo),
  },
  likes: {
    title: "Likes",
    dateField: "publishDate",
    deriveTitle: (e) => "Liked " + host(e.data.likeOf),
  },
};

/// Resolve the absolute site base URL from an Astro endpoint context, failing loudly when
/// `site` is unset. `astro.config.ts` always provides a fallback, so in practice this never
/// throws — but an `Invalid`/undefined site would otherwise surface as an opaque TypeError in
/// all 27 feed routes, so we give one clear message instead.
export function siteFrom(context: { site?: URL }): string {
  if (!context.site) {
    throw new Error(
      "[feeds] Astro `site` is not configured — set SITE_URL in .site-config so feeds can emit absolute URLs.",
    );
  }
  return context.site.href;
}

export function toFeedItem(collection: string, entry: FeedEntry, site: string): FeedItem {
  const cfg = FEED_COLLECTIONS[collection];
  if (!cfg) throw new Error(`No feed config for collection "${collection}"`);
  const rawDate = entry.data[cfg.dateField];
  const date = rawDate instanceof Date ? rawDate : new Date(rawDate);
  // An invalid/missing date would make `sortAndLimit` non-deterministic and crash
  // `renderAtom`/`renderJsonFeed` at `date.toISOString()` (RangeError). Fail at build instead.
  if (Number.isNaN(date.getTime())) {
    throw new Error(`[feeds] entry "${entry.id}" has a missing or invalid ${cfg.dateField}`);
  }
  const summary = (entry.data.summary ?? entry.data.caption ?? excerpt(entry.body, 280)) || "";
  return {
    title: cfg.deriveTitle(entry) || "Untitled",
    link: new URL(`/${collection}/${entry.id}/`, site).href,
    date,
    summary: String(summary),
  };
}

export function sortAndLimit(items: FeedItem[], limit?: number): FeedItem[] {
  const sorted = [...items].sort((a, b) => b.date.valueOf() - a.date.valueOf());
  return typeof limit === "number" ? sorted.slice(0, limit) : sorted;
}

export function renderRss(o: {
  title: string;
  description: string;
  site: string;
  items: FeedItem[];
}): Promise<Response> {
  return rss({
    title: o.title,
    description: o.description,
    site: o.site,
    items: o.items.map((i) => ({
      title: i.title,
      link: i.link,
      pubDate: i.date,
      description: i.summary,
    })),
  });
}

function escapeXml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

export function renderAtom(o: {
  title: string;
  site: string;
  feedUrl: string;
  items: FeedItem[];
}): Response {
  const updated = o.items[0]?.date ?? new Date(0);
  const entries = o.items
    .map(
      // Known limitation: <id> uses the permalink rather than a permanent tag: IRI (RFC 4287
      // §4.2.6). Renaming a slug therefore reads as a new entry in readers that saw the old URL.
      // This matches most simple RSS libraries; a stable tag: URI is a future improvement.
      (i) => `  <entry>
    <title>${escapeXml(i.title)}</title>
    <link href="${escapeXml(i.link)}"/>
    <id>${escapeXml(i.link)}</id>
    <updated>${i.date.toISOString()}</updated>
    <summary>${escapeXml(i.summary)}</summary>
  </entry>`,
    )
    .join("\n");
  const xml = `<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>${escapeXml(o.title)}</title>
  <id>${escapeXml(o.site)}</id>
  <link href="${escapeXml(o.site)}"/>
  <link rel="self" href="${escapeXml(o.feedUrl)}"/>
  <updated>${updated.toISOString()}</updated>
${entries}
</feed>
`;
  return new Response(xml, {
    headers: { "Content-Type": "application/atom+xml; charset=utf-8" },
  });
}

export function renderJsonFeed(o: {
  title: string;
  site: string;
  feedUrl: string;
  items: FeedItem[];
}): Response {
  const feed = {
    version: "https://jsonfeed.org/version/1.1",
    title: o.title,
    home_page_url: o.site,
    feed_url: o.feedUrl,
    items: o.items.map((i) => ({
      id: i.link,
      url: i.link,
      title: i.title,
      summary: i.summary,
      date_published: i.date.toISOString(),
    })),
  };
  return new Response(JSON.stringify(feed, null, 2), {
    headers: { "Content-Type": "application/feed+json; charset=utf-8" },
  });
}
