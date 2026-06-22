# Blog System for the Base Template — Design (#288)

> **Status:** Approved design, pre-implementation. Follow-up split out from #282/#287.

**Goal:** Make `BlogPost.astro` a real, rendered route. Today it exists only as a giscus injection target with no content collection and no route, so a giscus-configured site emits no commented page in `dist` (the gap #287 explicitly documented). This adds a working blog to every site's base template, which incidentally gives giscus a host page.

**Tech stack:** Astro 5 (`^5.0.0`), TypeScript, `tsconfig` extends `astro/tsconfigs/strict` (`noUnusedLocals`). Template lives at `Resources/Template/` and is a committed, first-class app resource.

## Scope decisions (from brainstorming)

- **Placement: core base template**, not on-demand staging. A blog is content infrastructure, not a third-party embed, so it ships in `src/` and every fresh site has it. This means **no Swift/engine change** — unlike the `integrations/` staging model, nothing is conditionally copied.
- **Surface: index + post pages + one starter post + a homepage nav link.** A complete, usable blog.
- **Schema: minimal.** `title`, `pubDate`, optional `description`, optional `draft`. No tags/author/hero-image (YAGNI for a v1 business-site blog; can be added later).

## Architecture

Pure Astro content-collection wiring. The giscus mechanism is untouched: `BlogPost.astro` keeps its existing `// anglesite:imports` frontmatter anchor and `<!-- anglesite:comments -->` body anchor, so the giscus descriptor's `injectAtAnchor` (shipped in #287) keeps working — now against a route that actually renders.

### Files (all under `Resources/Template/`)

1. **`src/content.config.ts`** *(new)* — Astro 5 content collection `blog` via the `glob()` loader:
   ```ts
   import { defineCollection, z } from "astro:content";
   import { glob } from "astro/loaders";

   const blog = defineCollection({
     loader: glob({ pattern: "**/*.md", base: "./src/content/blog" }),
     schema: z.object({
       title: z.string(),
       pubDate: z.coerce.date(),
       description: z.string().optional(),
       draft: z.boolean().default(false),
     }),
   });

   export const collections = { blog };
   ```

2. **`src/content/blog/welcome-to-your-blog.md`** *(new)* — one starter post. Frontmatter (`title`, `pubDate`, `description`) plus a few paragraphs of friendly placeholder copy explaining how to add and edit posts (where the Markdown lives, the frontmatter fields, the `draft` flag). Gives every fresh site a real page and giscus a host.

3. **`src/pages/blog/[...slug].astro`** *(new)* — the post route:
   ```astro
   ---
   import { getCollection, render } from "astro:content";
   import BlogPost from "../../layouts/BlogPost.astro";

   export async function getStaticPaths() {
     const posts = await getCollection("blog", ({ data }) => !data.draft);
     return posts.map((post) => ({ params: { slug: post.id }, props: { post } }));
   }

   const { post } = Astro.props;
   const { Content } = await render(post);
   ---

   <BlogPost title={post.data.title} description={post.data.description}>
     <Content />
   </BlogPost>
   ```
   `<Content />` lands in `BlogPost.astro`'s default `<slot />` inside `<article>`, immediately above the `<!-- anglesite:comments -->` anchor — so giscus (when configured) renders after the post body.

4. **`src/pages/blog/index.astro`** *(new)* — lists non-draft posts, newest first (`pubDate` desc), each linking to `/blog/<id>/`. Renders through `BaseLayout`. If the collection is empty (e.g. the only post is a draft), it renders an empty-state message and still builds.

5. **`src/pages/index.astro`** *(edit)* — add a simple nav link to `/blog/` in the hero section.

## Data flow

```
src/content/blog/*.md
   → glob() loader → getCollection("blog")
      → [...slug].astro getStaticPaths (drafts filtered) → /blog/<slug>/ via BlogPost.astro
      → index.astro listing (drafts filtered) → /blog/
BlogPost.astro <!-- anglesite:comments --> ← giscus <Comments> injected on setup (unchanged, #287)
```

## Error handling / edge cases

- **Drafts** (`draft: true`) are excluded from both `getStaticPaths` and the index listing — no page emitted, no link shown.
- **Empty collection** (all drafts / no posts) → index renders empty-state copy; `getStaticPaths` returns `[]`; build succeeds with no `/blog/<slug>/` pages.
- **Schema violations** (missing `title`, unparseable `pubDate`) surface as Astro build errors — fail loud, not silent.
- **`noUnusedLocals`** — every imported symbol (`getCollection`, `render`, `BlogPost`, `BaseLayout`) is used in each file.

## Testing / acceptance

1. **Fresh scaffold builds the blog:** `npm install && npm run build` on a freshly scaffolded site emits `dist/blog/index.html` and `dist/blog/welcome-to-your-blog/index.html`.
2. **giscus end-to-end (closes the #287 gap):** a scaffold with giscus configured (`.site-config` giscus keys + the descriptor's inject run) emits `https://giscus.app/client.js` in the rendered post page. This is the concrete unblock #288 exists for.
3. **Draft exclusion:** a post with `draft: true` produces no `dist/blog/<slug>/` output and no index link.
4. **Swift suite stays green:** run the full `swift test` (`DEVELOPER_DIR` + `ANGLESITE_PLUGIN_PATH` set). Suites that load the real template fixture — `SiteScaffolderTests`, `SiteScaffolderPackageTests`, `IntegrationTemplateAssetsTests`, `TemplateRuntimeTests`, and the content-graph/scanner suites — must not regress on the added `src/content/` + `src/pages/blog/` files. Update any structural expectation that legitimately changes.

## Out of scope

- Richer frontmatter (tags + tag pages, author, hero image, `updatedDate`) — deferred; the schema is intentionally minimal.
- RSS feed, pagination, reading-time — not needed for v1.
- Any change to the giscus descriptor, `MarkerInjector`, or other Swift/engine code — the existing injection already works against `BlogPost.astro`.
