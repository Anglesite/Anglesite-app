import { defineCollection, z } from "astro:content";
import { glob } from "astro/loaders";

// Blog posts live as Markdown in src/content/blog/. The glob loader derives each
// entry's `id` from its filename (e.g. welcome-to-your-blog.md -> "welcome-to-your-blog"),
// which becomes the /blog/<id>/ URL.
const blog = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/blog" }),
  schema: z.object({
    title: z.string(),
    pubDate: z.coerce.date(),
    description: z.string().optional(),
    draft: z.boolean().default(false),
  }),
});

const notes = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/notes" }),
  schema: z.object({
    publishDate: z.coerce.date(),
    tags: z.array(z.string()).optional(),
  }),
});

const articles = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/articles" }),
  schema: z.object({
    title: z.string(),
    summary: z.string().optional(),
    publishDate: z.coerce.date(),
    updated: z.coerce.date().optional(),
    tags: z.array(z.string()).optional(),
  }),
});

const photos = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/photos" }),
  schema: z.object({
    image: z.string(),
    caption: z.string().optional(),
    publishDate: z.coerce.date(),
    tags: z.array(z.string()).optional(),
  }),
});

const albums = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/albums" }),
  schema: z.object({
    title: z.string(),
    images: z.array(z.string()),
    publishDate: z.coerce.date(),
    tags: z.array(z.string()).optional(),
  }),
});

const bookmarks = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/bookmarks" }),
  schema: z.object({
    bookmarkOf: z.string().url(),
    title: z.string().optional(),
    publishDate: z.coerce.date(),
    tags: z.array(z.string()).optional(),
  }),
});

const replies = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/replies" }),
  schema: z.object({
    inReplyTo: z.string().url(),
    publishDate: z.coerce.date(),
  }),
});

const likes = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/likes" }),
  schema: z.object({
    likeOf: z.string().url(),
    publishDate: z.coerce.date(),
  }),
});

export const collections = { blog, notes, articles, photos, albums, bookmarks, replies, likes };
