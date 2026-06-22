---
title: "Welcome to your blog"
pubDate: 2026-01-01
description: "How to add and edit posts on your new Anglesite blog."
---

This is your blog's first post. Every Anglesite site comes with a blog ready to go.

## Adding a post

Create a new Markdown file in `src/content/blog/`. The file name becomes the
post's URL — `my-first-update.md` is published at `/blog/my-first-update/`.

Each post starts with frontmatter between `---` fences:

- **title** — shown as the heading and in the post list (required)
- **pubDate** — the publication date, e.g. `2026-01-15` (required)
- **description** — a one-line summary for search engines and previews (optional)
- **draft** — set to `true` to keep a post out of the build while you work on it (optional)

Write the post body in Markdown below the frontmatter. Delete this starter post
whenever you're ready to publish your own.
