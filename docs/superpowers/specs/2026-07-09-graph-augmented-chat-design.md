# Free-form cross-node site Q&A (#314)

## Status

Design for the remaining scope of #314 after #614 (shipped, PR #627) covered single-node
"Explain this node" in the Site Graph Explorer. This design covers free-form, cross-node
questions — e.g. "How is navigation generated?", "Why is this image appearing here?" — that
require synthesizing facts from multiple graph nodes/edges, not just one selected node.

## Problem

The app's Chat panel (`ChatModel`/`ChatView`) already answers general questions using an
on-device model (`FoundationModelAssistant`, per the #459 LLM policy: on-device first, no
network fallback) enriched with content search over `SiteKnowledgeIndex`
(`KnowledgeAugmentedAssistant`, `Sources/AnglesiteCore/KnowledgeAugmentedAssistant.swift`). That
index does per-file *text* search — it can tell the model what a file says, but not how files
relate: it has no notion of the dependency graph (`imports`, `usesLayout`, `referencesAsset`
edges) or transitive impact that `SiteGraphExplorer`/`ImpactAnalysis` already compute for the
Site Graph Explorer and #614's single-node explainer.

Structural questions like "why is this image appearing here" or "how is navigation generated"
need those graph facts, not file text, to answer accurately — and per the issue, every statement
in the answer must cite its source file.

## Non-goals

- No new agentic tool-calling loop. `FoundationModelAssistant.converse` already supports
  FoundationModels `Tool`s (e.g. `SearchContentTool`), but tool calls run opaquely inside
  `LanguageModelSession.streamResponse` with no call-result telemetry exposed
  (`FoundationModelAssistant.swift:229-230`) — there is no hook today to turn a tool's return
  value into a `RetrievedCitation`. Front-loaded retrieval (classic RAG, matching the existing
  `KnowledgeAugmentedAssistant` pattern) is simpler and keeps citations exact.
- No new UI surface. Reuses the existing Chat panel end to end (see decision log below).
- No semantic/vector search. `SiteKnowledgeIndex.search` is keyword/term-scored, not embeddings
  (`SiteKnowledgeIndex.swift:102-131`); the new graph seed-matching step follows the same style
  for consistency, not a new dependency.
- No multi-hop graph traversal algorithm. `ImpactAnalysis.Report` is already a full
  reverse-transitive closure from one target node (`ImpactAnalysis.swift:49`), so a single seed
  node's impact facts already answer "what does this affect, however indirectly" without new
  traversal code.

## Design

### Architecture

Add a second decorator alongside the existing one, composed the same way:

```
SiteGraphAugmentedAssistant(
    base: KnowledgeAugmentedAssistant(base: FoundationModelAssistant(...), index: knowledgeIndex),
    snapshotProvider: { await MainActor.run { graphExplorer.snapshot } }
)
```

`SiteGraphAugmentedAssistant` (new, `AnglesiteCore`, actor, conforms to `ConversationalAssistant`)
runs before every turn, alongside (not instead of) the existing content-index enrichment:

1. Read the live `SiteGraphExplorerSnapshot` via `snapshotProvider`. The snapshot is already
   built once at window load (`SiteWindowModel.swift:1096`, `graphExplorer.start(...)`) and kept
   current by file-watching (`SiteFileWatching`) — this step never rebuilds the graph, just reads
   the window's existing copy.
2. Score every node in the snapshot against the question's words (case-insensitive substring
   match against `title`, `route`, `filePath`), take the top 3 scoring nodes as "seed nodes." Zero
   matches → contribute nothing this turn (plain chat and content-only questions are unaffected).
3. For each seed node, build its fact list — reusing `SiteGraphExplainPrompt`'s existing per-node
   fact logic (direct `dependsOn`/`referencedBy` neighbors + `ImpactAnalysis.Report`, capped at
   `maxListedNames` = 12 per group, same as #614) — and prepend a "Facts:" block per seed node to
   the prompt, instructing the model to synthesize only from these facts and cite file paths.
4. Emit one `RetrievedCitation` per seed node (`path` = node's `filePath`, `title` = node's
   `title`, `kind` mapped from `SiteGraphNodeKind`, `score` = the match score).

### Components

- **`SiteGraphExplainPrompt` refactor** (`Sources/AnglesiteCore/SiteGraphNodeExplainer.swift`):
  extract the per-node fact list into a reusable
  `static func facts(node:impact:dependsOn:referencedBy:) -> [String]`, called by both the
  existing single-node `prompt(...)` (unchanged behavior) and the new multi-node context builder.
- **`SiteGraphAugmentedAssistant`** (new file, `Sources/AnglesiteCore/`): owns seed-node scoring,
  fact assembly, and citation emission. Depends only on `SiteGraphExplorerSnapshot`,
  `ImpactAnalysis`, and `SiteGraphExplainPrompt` — no FoundationModels import, so it stays
  testable on any toolchain (matching the `#if compiler(>=6.4)` gating pattern used elsewhere).
- **`SiteAssistantSessionFactory.makeSession`** (`Sources/AnglesiteApp/SiteAssistantSessionFactory.swift`):
  gains a `graphSnapshotProvider: @Sendable () async -> SiteGraphExplorerSnapshot` parameter,
  used to wrap the existing `assistant` chain with `SiteGraphAugmentedAssistant`.
- **`SiteWindowModel`**: supplies the provider from its existing `graphExplorer` property
  (`SiteWindowModel.swift:147`), and gains `revealCitationInGraph(path:) -> Bool` (see below).

### Citations and navigation

`RetrievedCitation` (`Sources/AnglesiteCore/RetrievedCitation.swift`) is unchanged — no new
fields. `SiteGraphNodeKind` maps onto the existing `SiteKnowledgeIndex.Document.Kind` used by
`RetrievedCitation.kind`:

| `SiteGraphNodeKind` | `SiteKnowledgeIndex.Document.Kind` |
|---|---|
| `.page` | `.page` |
| `.layout` | `.layout` |
| `.component` | `.component` |
| `.collection` | `.content` |
| `.contentEntry` | `.content` |
| `.asset` | `.other` |
| `.style` | `.style` |

Clicking a citation should reveal it in context, not just open the raw file. `ChatView` gains a
`revealCitation: (String) -> Bool` closure param (mirroring the existing `onOpenNode` callback
pattern already used for graph clicks, `SiteWindow.swift:690-692`), threaded down to
`CitationRowView`/`CitationChip`. `SiteWindow` wires it to a new
`SiteWindowModel.revealCitationInGraph(path:)`, which looks up a node with matching `filePath` in
`graphExplorer.snapshot.nodes`; if found, it calls `showGraph()` then `graphExplorer.revealNode(node)`
and returns `true`. `CitationChip`'s action tries this closure first; if it returns `false` (no
matching node) or the closure is `nil` (tests/previews), it falls back to today's
`NSWorkspace.shared.open`. This applies uniformly to every citation, not just graph-sourced ones —
a content-index citation for a page gets "reveal in graph" too, for free, if that page happens to
be a graph node.

### Error handling

`SiteGraphAugmentedAssistant` only reads an in-memory snapshot and never calls the model directly
— it cannot itself throw `AssistantError.unavailable`. That error still originates solely from
the underlying `FoundationModelAssistant` when Apple Intelligence is off, and is surfaced by
Chat's existing error/unavailable UI unchanged.

### Testing

- Seed-node scoring: unit tests mirroring `SiteGraphExplainPromptTests.swift` — matches by title,
  route, filePath; zero matches produce no graph facts and no citations; a tie-breaking/ordering
  case; a cap-at-3 case.
- `SiteGraphExplainPrompt.facts(...)` refactor: existing `SiteGraphExplainPromptTests` must keep
  passing unchanged (pure extraction, no behavior change).
- `SiteWindowModel.revealCitationInGraph`: matching path reveals + switches pane; non-matching
  path returns `false`.
- `ChatView`/`CitationRowView`: citation click calls `revealCitation` before falling back to
  `NSWorkspace.shared.open` (existing `CitationRowView` has no tests today per the exploration —
  add coverage for the new fallback branch specifically, not a full retrofit).

## Decision log

- **UI surface**: extend the existing Chat panel (not a new input box in the Site Graph
  Explorer). Reuses all existing streaming/cancel/error chrome; avoids duplicating chat UI.
- **Citation format**: inline clickable citations, using the existing `CitationRowView` chip UI
  already shipped for content-index citations — no new rendering needed.
- **Citation click action**: reveal the node in the Site Graph Explorer (switch pane + select),
  falling back to opening the file when the path isn't a graph node.
