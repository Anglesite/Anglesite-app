import { defineCollection } from "astro:content";
import { glob } from "astro/loaders";
import { z } from "astro/zod";

// Shared outbound-social metadata. POSSE is explicit per entry; `syndication` is written back by
// Anglesite after the remote APIs return and is projected as u-syndication by the layouts.
const socialFields = {
  posse: z.array(z.string()).optional(),
  syndicateTo: z.array(z.string()).optional(),
  "syndicate-to": z.array(z.string()).optional(),
  posseText: z.string().optional(),
  socialText: z.string().optional(),
  syndication: z.array(z.string().url()).optional(),
};

// Blog posts live as Markdown in src/content/blog/. The glob loader derives each
// entry's `id` from its filename (e.g. welcome-to-your-blog.md -> "welcome-to-your-blog"),
// which becomes the /blog/<id>/ URL.
const blog = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/blog" }),
  schema: z.object({
    ...socialFields,
    title: z.string(),
    pubDate: z.coerce.date(),
    description: z.string().optional(),
    draft: z.boolean().default(false),
  }).strict(),
});

const notes = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/notes" }),
  schema: z.object({
    ...socialFields,
    publishDate: z.coerce.date(),
    tags: z.array(z.string()).optional(),
  }).strict(),
});

const articles = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/articles" }),
  schema: z.object({
    ...socialFields,
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
    ...socialFields,
    image: z.string(),
    caption: z.string().optional(),
    publishDate: z.coerce.date(),
    tags: z.array(z.string()).optional(),
  }).strict(),
});

const albums = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/albums" }),
  schema: z.object({
    ...socialFields,
    title: z.string(),
    images: z.array(z.string()),
    publishDate: z.coerce.date(),
    tags: z.array(z.string()).optional(),
  }).strict(),
});

const bookmarks = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/bookmarks" }),
  schema: z.object({
    ...socialFields,
    bookmarkOf: z.string().url(),
    title: z.string().optional(),
    publishDate: z.coerce.date(),
    tags: z.array(z.string()).optional(),
  }).strict(),
});

const replies = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/replies" }),
  schema: z.object({
    ...socialFields,
    inReplyTo: z.string().url(),
    publishDate: z.coerce.date(),
  }).strict(),
});

const likes = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/likes" }),
  schema: z.object({
    ...socialFields,
    likeOf: z.string().url(),
    publishDate: z.coerce.date(),
  }).strict(),
});

const announcements = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/announcements" }),
  schema: z.object({
    ...socialFields,
    title: z.string(),
    publishDate: z.coerce.date(),
  }).strict(),
});

const events = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/events" }),
  schema: z.object({
    ...socialFields,
    name: z.string(),
    start: z.coerce.date(),
    end: z.coerce.date().optional(),
    location: z.string().optional(),
  }).strict(),
});

const reviews = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/reviews" }),
  schema: z.object({
    ...socialFields,
    itemReviewed: z.string(),
    rating: z.number(),
    publishDate: z.coerce.date(),
  }).strict(),
});

const members = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/members" }),
  schema: z.object({
    ...socialFields,
    name: z.string(),
    role: z.string().optional(),
    joinedDate: z.coerce.date(),
    photo: z.string().optional(),
    links: z.array(z.string()).optional(),
  }).strict(),
});

export const collections = { blog, notes, articles, photos, albums, bookmarks, replies, likes, announcements, events, reviews, members };
