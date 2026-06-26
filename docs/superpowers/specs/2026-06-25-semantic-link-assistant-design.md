# On-device Semantic Index + Internal Link Assistant — Design

**Date:** 2026-06-25
**Issues:** #312 (AI Internal Link Assistant), foundation of #307 / #311 (RAG knowledge index)
**Status:** Approved — pending implementation plan
**Hard prerequisite:** PR #329 (`SiteKnowledgeIndex`, #307 lexical index) merged to `main`

## Summary

Add an **on-device semantic ranking layer** on top of the lexical `SiteKnowledgeIndex`
landing in PR #329, and use it to ship the #312 Internal Link Assistant: a Related-Pages
panel that suggests semantically relevant internal links while editing, plus a semantic
upgrade to the existing `SearchKnowledgeTool` so the AI-editing path benefits too.

The semantic layer is the reusable foundation the rest of the #307–314 cluster
(RAG Q&A, related content, dead-asset detection) can later consume — but this spec owns
only the index's semantic layer and the #312 consumers. Full RAG retrieval and the other
cluster features are out of scope and get their own specs.

## Goals

- Rank a site's pages/posts by **semantic similarity**, not just keyword matching (#312's
  core requirement), entirely **on-device** with no external API (project strategy:
  Apple Intelligence / NaturalLanguage, no network embedding service).
- Deliver the #312 link assistant: a Related-Pages side panel with confidence scores,
  one-click link insertion, and ignore.
- Surface the cheap link-graph wins (reciprocal links, isolated pages, over-linking) from
  data #329 already extracts.
- Leave a clean, additive seam so chunk-level granularity and the broader RAG cluster can
  build on this later.

## Non-goals

- Inline-while-typing suggestions in the edit overlay (a follow-up consumer).
- A whole-site link/SEO audit report (future #310-style spec).
- Full RAG question-answering retrieval / citations beyond what #329 already provides.
- Chunk-level (paragraph) embeddings — the API is designed to accept them later, but v0 is
  document-level only.
- Cloudflare Vectorize / remote index (a future extension noted in #307).

## Background: what PR #329 provides

PR #329 (`codex/implement-307`) lands `SiteKnowledgeIndex`, an actor that is the lexical
foundation. This spec builds **on top of it** and does not duplicate it.

`SiteKnowledgeIndex` already:

- Walks the whole project (`src/pages`, `src/content`, `src/components`, `src/layouts`,
  config, CSS, scripts — broader than `ContentScanner`), skipping `.astro`, `.git`, `dist`,
  `node_modules`, etc., capping files at 512 KB.
- Produces a `Document` per file carrying: `path`, `kind` (page/post/component/layout/
  content/config/style/script/other), `title`, parsed `frontmatter`, `headings`,
  **`internalLinks`**, full `excerptText` (source), and `lastModified`.
- Scores documents lexically (term + phrase, field-weighted) and returns cited
  `SearchResult`s with line ranges via `search(siteID:query:options:)`.
- Maintains the index in-memory with `rebuild` / `upsertFile` / `removeFile` / `unload`,
  wired through `PreviewModel`, `SiteWindow`, `LocalSiteRuntime`, and exposed to the
  on-device model via `SearchKnowledgeTool`.

It is **intentionally lexical** — no embeddings. That gap is exactly what this spec fills.

## Architecture

Two new units in `AnglesiteCore`, one upgrade, one new view.

### `EmbeddingProvider` (protocol — the testable seam)

```swift
public protocol EmbeddingProvider: Sendable {
    var dimension: Int { get }
    /// Returns a unit-normalized embedding, or throws if no model/asset is available.
    func embed(_ text: String) async throws -> [Float]
}
```

- **Production:** `NLContextualEmbeddingProvider` — Apple's on-device transformer embedding
  (`NLContextualEmbedding`), mean-pooled to a single passage vector, multilingual (matters
  for i18n sites). If the contextual asset is unavailable at runtime it falls back to
  `NLEmbedding.sentenceEmbedding(for:)`. Gated/structured like the existing on-device code so
  its absence on CI is handled, not fatal.
- **Tests:** `FakeEmbeddingProvider` — deterministic vectors so all ranking, caching, and
  incremental logic is CI-testable without the real model (same approach as the
  FoundationModels suites).

The protocol is the only thing consumers depend on; the model choice is swappable without
touching the ranker.

### `SemanticRanker` (actor)

Consumes `SiteKnowledgeIndex.documents(siteID:)`; holds per-document embedding vectors;
offers semantic and hybrid ranking. `SiteKnowledgeIndex` itself stays untouched.

Responsibilities:

- **Sync from the lexical index.** Given the index's documents, compute a stable
  `contentHash` per document over the embedded text (title + headings + excerpt). On a cache
  hit, load the vector; on a miss, call `EmbeddingProvider.embed` and store it (and write the
  cache entry). Mirrors #329's `upsertFile` / `removeFile` so a single edit re-embeds exactly
  one document.
- **Embedded text (v0, document-level):** `title` + `headings` joined + a leading slice of
  `excerptText`. Documents with too little text get no vector (they fall back to lexical).
- **Rank.** `relatedDocuments(siteID:to:limit:)` returns top-k by cosine similarity to a
  source document's vector; `search(siteID:queryVector:limit:)` ranks against an arbitrary
  query vector. A **hybrid** mode blends cosine with #329's lexical score into a normalized
  `confidence` in 0…1.
- **Granularity seam.** The vector store keys on an opaque entry id with an optional
  `chunkID`. v0 always uses the document id; chunk-level (#311) adds chunk ids later without
  changing the consumer API.

### `SemanticIndexCache` (persistence — embeddings only)

The lexical index stays in-memory (cheap to rebuild, per #329). Only the **embeddings**
(expensive to recompute) persist:

- File: `Config/caches/semantic-index.json` — app-owned per-site state, **never in git**
  (lives in the package's `Config/`, outside `Source/`).
- Entry: `{ docID, contentHash, dim, vector }`.
- On load: entries whose `dim` ≠ the current provider's dimension, or that fail to decode,
  are dropped and re-embedded. Cache corruption is never fatal.
- On `contentHash` mismatch (file changed): treated as a miss → re-embed → overwrite entry.

### `LinkGraph` (pure helper)

Reads `Document.internalLinks` across a site (no embeddings) to compute:

- **Reciprocal-link gaps:** A links to B but B does not link back to A.
- **Isolated pages:** pages with no inbound internal links.
- **Over-linked pages:** outbound link count above a threshold.

These ship as affordances in the panel, not a standalone audit.

## Consumers

### Related-Pages panel (#312 UI — net-new)

A panel in the preview-pane header family (same pattern as `ChatView` / drawer views),
scoped to the page currently being edited:

- Rows of related pages: title, route, **confidence** (from `SemanticRanker` hybrid score),
  `[Insert link]`, `[Ignore]`.
- Self and already-linked targets (from the source doc's `internalLinks`) are filtered out.
- A small "isolated page" / "missing reciprocal link" hint section driven by `LinkGraph`.
- **Insert** routes through the existing `EditRouter` / apply-edit pipeline — constructs a
  markdown or `<a>` link to the target route at the current selection. No new mutation path.
- **Ignore** dismisses a suggestion for the session (no persistence in v0).

UI stays thin; ranking, filtering, and confidence live in `SemanticRanker` / `LinkGraph`
so they are testable in `AnglesiteCore`.

### `SearchKnowledgeTool` semantic upgrade (existing — from #329)

The tool #329 already ships gains a semantic/hybrid mode: embed the query string via
`EmbeddingProvider`, blend cosine similarity with the existing lexical score. Pure-lexical
remains the fallback when embeddings are unavailable, so chat-driven editing ("add links to
related pages") improves with no UI change.

## Data flow

**Indexing** (after #329's `rebuild` / `upsertFile`):

```
SiteKnowledgeIndex.documents(siteID)          // lexical docs, in-memory
  → SemanticRanker.sync(documents)
      for each doc: contentHash(title + headings + excerpt)
        ├─ hash in Config/ cache?  → load vector
        └─ miss                    → EmbeddingProvider.embed(...) → store + write cache
  → vectors held in-memory, keyed by document id
```

**Query — Related-Pages panel:**

```
currentPage docID → its vector → cosine vs all same-site vectors
  → top-k, drop self + already-linked (doc.internalLinks)
  → hybrid re-rank with #329 lexical score → confidence 0…1
  → rows: title, route, confidence, [Insert] [Ignore]
```

**Query — `SearchKnowledgeTool`:** embed query string → blend cosine with lexical score →
cited results; pure-lexical fallback when embeddings unavailable.

## Error handling

- **No embedding model** (CI, or asset not downloaded): `EmbeddingProvider.embed` throws →
  `SemanticRanker` degrades to #329's pure-lexical ranking; the panel shows a one-line
  "semantic ranking unavailable — showing keyword matches" note. Degradation is surfaced,
  never silent (logs-are-sacred).
- **Cache corruption / dimension mismatch:** offending entries skipped and re-embedded;
  never fatal.
- **Empty or too-short content:** no vector produced; that document falls back to lexical
  ranking.
- **Insert failure:** surfaced via the existing apply-edit failure path (`no-match`,
  `ambiguous-match`, etc.) — the app does not silently swallow it.

## Testing

- `FakeEmbeddingProvider` (deterministic vectors) drives:
  - `SemanticRanker` cosine + hybrid ranking and top-k selection.
  - Cache hit / miss / `contentHash` invalidation / dimension-mismatch drop.
  - Incremental `upsert` / `remove` re-embedding exactly the changed document.
- `LinkGraph` reciprocal / isolated / over-linked math against fixture `internalLinks`.
- `NLContextualEmbeddingProvider` gets a smoke test gated like the other on-device suites
  (does not run on CI).
- Panel + insert kept thin; ranking/confidence/filter logic pushed into `AnglesiteCore`
  types so it is covered without a hosted app target.

## Dependencies & sequencing

1. **PR #329 merged first** — this spec is written against `SiteKnowledgeIndex` as it lands;
   the `SemanticRanker` builds on top of `main`.
2. Then: `EmbeddingProvider` + `FakeEmbeddingProvider` → `SemanticRanker` + cache →
   `LinkGraph` → `SearchKnowledgeTool` upgrade → Related-Pages panel + insert.

## Open questions

None blocking. Chunk-level granularity, an inline-while-typing consumer, a whole-site audit,
and Cloudflare Vectorize export are deliberately deferred to later specs that consume this
layer.
