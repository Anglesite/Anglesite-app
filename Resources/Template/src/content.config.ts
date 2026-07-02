import { defineCollection } from "astro:content";
import { glob } from "astro/loaders";
import { z } from "astro/zod";

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
  }).strict(),
});

const notes = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/notes" }),
  schema: z.object({
    publishDate: z.coerce.date(),
    tags: z.array(z.string()).optional(),
  }).strict(),
});

const articles = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/articles" }),
  schema: z.object({
    title: z.string(),
    summary: z.string().optional(),
    publishDate: z.coerce.date(),
    updated: z.coerce.date().optional(),
    tags: z.array(z.string()).optional(),
  }).strict(),
});

const photos = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/photos" }),
  schema: z.object({
    image: z.string(),
    caption: z.string().optional(),
    publishDate: z.coerce.date(),
    tags: z.array(z.string()).optional(),
  }).strict(),
});

const albums = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/albums" }),
  schema: z.object({
    title: z.string(),
    images: z.array(z.string()),
    publishDate: z.coerce.date(),
    tags: z.array(z.string()).optional(),
  }).strict(),
});

const bookmarks = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/bookmarks" }),
  schema: z.object({
    bookmarkOf: z.string().url(),
    title: z.string().optional(),
    publishDate: z.coerce.date(),
    tags: z.array(z.string()).optional(),
  }).strict(),
});

const replies = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/replies" }),
  schema: z.object({
    inReplyTo: z.string().url(),
    publishDate: z.coerce.date(),
  }).strict(),
});

const likes = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/likes" }),
  schema: z.object({
    likeOf: z.string().url(),
    publishDate: z.coerce.date(),
  }).strict(),
});

const announcements = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/announcements" }),
  schema: z.object({
    title: z.string(),
    publishDate: z.coerce.date(),
  }).strict(),
});

const events = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/events" }),
  schema: z.object({
    name: z.string(),
    start: z.coerce.date(),
    end: z.coerce.date().optional(),
    location: z.string().optional(),
  }).strict(),
});

const reviews = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/reviews" }),
  schema: z.object({
    itemReviewed: z.string(),
    rating: z.number(),
    publishDate: z.coerce.date(),
  }).strict(),
});

export const collections = { blog, notes, articles, photos, albums, bookmarks, replies, likes, announcements, events, reviews };
