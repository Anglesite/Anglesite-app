/**
 * Routed content collections, declared once so the dynamic route and the per-vocabulary
 * layouts can't drift from each other (or from content.config.ts).
 */

/** The eight h-entry collections that share Hentry.astro. */
export const HENTRY_COLLECTIONS = [
  "notes", "articles", "photos", "albums",
  "bookmarks", "replies", "likes", "announcements",
] as const;
export type HentryCollection = (typeof HENTRY_COLLECTIONS)[number];

/** Every routed collection: h-entry plus the vocabularies with their own layout. */
export const ENTRY_COLLECTIONS = [
  ...HENTRY_COLLECTIONS, "events", "reviews",
] as const;
export type EntryCollection = (typeof ENTRY_COLLECTIONS)[number];
