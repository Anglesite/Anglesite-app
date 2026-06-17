# C.8 — Local RAG via `SpotlightSearchTool`

**Issue:** [#158](https://github.com/Anglesite/Anglesite-app/issues/158) · **Parent:** #134 (Phase C) · **Date:** 2026-06-16

## Goal

Give the on-device assistant retrieval-augmented generation over the user's own site
content with no custom retrieval code. Phase A's `ContentSpotlightIndexer` already publishes
pages, posts, and images into the system Core Spotlight index as `IndexedEntity`s. This task
wires Apple's built-in `SpotlightSearchTool` into `FoundationModelAssistant` so the model can
query that index directly — answering questions like "what did I write about SwiftUI last
month?" entirely on-device.

## API correction

The Phase C spec (`2026-06-11-siri-ai-integration-design.md`, §C.6) shows a `.spotlight`
static tool member:

```swift
let session = LanguageModelSession(tools: [.spotlight, ...])   // does NOT exist
```

That shorthand never shipped. The actual macOS 27 API (WWDC26, *"LLM search using Core
Spotlight"*) is a concrete type, `SpotlightSearchTool`, requiring `import CoreSpotlight`
alongside `import FoundationModels`:

```swift
let session = LanguageModelSession(tools: [SpotlightSearchTool()], instructions: instructions)
```

A default-initialized `SpotlightSearchTool()` searches the app's Core Spotlight index — the
same `CSSearchableIndex.default()` that `ContentSpotlightIndexer` writes to — so no
configuration is needed. (The tool also accepts a `FileSource` config for sandbox file-path
search; we do not use it, since our content is indexed as entities, not files.)

## Design

All changes are in `Sources/AnglesiteCore/FoundationModelAssistant.swift`.

### 1. Import

Add `import CoreSpotlight` next to `import FoundationModels` (both inside the existing
`#if compiler(>=6.4)` gate).

### 2. Attach unconditionally in `makeSession(context:)`

`SpotlightSearchTool` needs no app-supplied dependency, so it attaches to **every** session.
The existing edit/search pair stays gated on `editBridge`/`contentGraph`:

```swift
var tools: [any Tool] = [SpotlightSearchTool()]
if let editBridge, let contentGraph {
    tools.append(ApplyEditTool(bridge: editBridge, siteID: context.siteID,
                               contextSelector: context.selectedElementSelector))
    tools.append(SearchContentTool(contentGraph: contentGraph, siteID: context.siteID))
}
return LanguageModelSession(tools: tools, instructions: instructions)
```

The previous tool-less `LanguageModelSession(instructions:)` branch is removed — every
session now carries at least the Spotlight tool.

Note: `makeSession` already throws `AssistantError.unavailable` *before* this point when the
on-device model is absent, so `SpotlightSearchTool()` is only ever constructed on a device
where the model runs. This sidesteps any concern about touching the tool type on CI.

### 3. `capabilities.supportsTools` → unconditionally `true`

Every session carries Spotlight, so the advertised capability drops its
`editBridge != nil && contentGraph != nil` expression and becomes `true`.

### 4. `attachedToolNames`

Reported in the `.started` event for the chat UI. Always include a Spotlight label; add the
edit/search names only when those dependencies are present:

```swift
private var attachedToolNames: [String] {
    var names = ["spotlightSearch"]   // display label for the .started event
    if editBridge != nil && contentGraph != nil {
        names += [ApplyEditTool.toolName, SearchContentTool.toolName]
    }
    return names
}
```

`"spotlightSearch"` is a display label, not Apple's internal tool name (which carries no
telemetry to the app anyway — see Testing).

## Why "always attach" is safe

The one-shot paths (`generate`, and `generateStructured` for alt-text/summaries) now carry
the tool too. Guided generation (`respond(generating:)`) constrains output to the
`@Generable` result type and will not spuriously call a search tool; free-text `generate`
*could* search, which is harmless and arguably useful. This is an accepted, deliberate
trade-off over gating the tool behind a dependency it does not have.

## Testing

Two facts are deliberately **not** asserted, because they cannot be honestly tested:

- **Tool invocation.** The on-device model exposes no tool-call telemetry — `converse`'s own
  docs note tool calls "run opaquely inside the session." There is no way to assert the model
  invoked `SpotlightSearchTool`.
- **Tool internals.** `SpotlightSearchTool` is Apple's opaque type with no injectable seam
  (unlike `ContentSpotlightIndexer`, which has the `ContentSpotlightBackend` protocol), and CI
  has no live model (#128).

Testing therefore splits into three tiers:

### Tier 1 — CI-safe (the automated deliverable)

In `Tests/AnglesiteCoreTests/FoundationModelAssistantTests.swift`:

- Update `onDeviceCapabilities`: `#expect(!caps.supportsTools)` → `#expect(caps.supportsTools)`.
- Add a test: an assistant built with **no** `editBridge`/`contentGraph` still reports
  `supportsTools == true` — proving Spotlight is unconditional.

These read `capabilities`, which is `nonisolated` and never touches `SystemLanguageModel`, so
they run on any toolchain ≥6.4 without the model.

### Tier 2 — Device-only smoke (guarded by `modelAvailable()`, skips on CI)

The closest automatable form of the issue's "integration test": index a known entity through
`ContentSpotlightIndexer`'s live backend, ask the assistant a question only answerable from
that entity, and assert the reply contains the planted fact. Written, but flagged in-code as
**model-dependent and index-propagation-racy** (the system indexes asynchronously) — a smoke,
not a deterministic gate, consistent with the existing live `converse*` tests.

### Tier 3 — Manual

True end-to-end RAG ("what did I write about SwiftUI last month?") belongs in the Phase C
manual smoke, alongside B.6/D.5. The comprehensive automated suite is #161's scope.

**Net:** #158 lands the wiring + the Tier-1 capability tests + a guarded Tier-2 smoke, and
explicitly does not claim to verify tool invocation on CI — avoiding a silently-skipping test
that would read as green coverage when it is not.

## Out of scope

- The other macOS 27 built-in tools (`OCRTool`, `BarcodeReaderTool`).
- `FileSource`-configured Spotlight search over sandbox file paths.
- The full Phase C test suite (#161) and the Phase C manual smoke.
