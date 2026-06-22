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

export const collections = { blog };
