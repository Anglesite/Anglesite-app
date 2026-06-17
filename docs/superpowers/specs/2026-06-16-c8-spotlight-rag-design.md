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

A **default**-initialized `SpotlightSearchTool()` is unusable on the on-device model: its
default `GuidanceLevel.complete` injects a ~13,000-token query-construction manual into the
prompt, which is over 3× the on-device model's entire 4,096-token context window. Measured
empirically — a trivial "say hello" prompt fails with *"Provided 13,053 tokens, but the
maximum allowed is 4,096."* The tool must be configured with a leaner guidance level:

```swift
SpotlightSearchTool(configuration: .init(
    sources: [.coreSpotlight],
    guide: .init(level: .focused(.items), format: .compact)))
```

`.focused(.items)` scopes the guidance to the *items* content domain (title/text/created/
modified) — exactly our pages/posts — and `.compact` trims the response format. Measured:
this configuration fits and the model responds normally. (`.dynamic(GuidanceProfile(...))`
also fits and offers finer control; `.focused(.items)` is the simplest fit for text content.)

## Design

All changes are in `Sources/AnglesiteCore/FoundationModelAssistant.swift`.

### 1. Import

Add `import CoreSpotlight` next to `import FoundationModels` (both inside the existing
`#if compiler(>=6.4)` gate). The `_CoreSpotlight_FoundationModels` cross-import overlay that
vends `SpotlightSearchTool` activates automatically when both are imported.

### 2. Attach on the **conversational path only**

Even the slimmed `.focused`/`.compact` guide still consumes part of the 4,096-token budget on
every session it is attached to. The one-shot paths (`generate`, and `generateStructured` for
alt-text/summaries) never use retrieval — paying that tax there only steals context from the
generation itself. So Spotlight attaches **only** to the multi-turn `converse` session, where
RAG is the point. `makeSession` gains an opt-in flag; only `conversationSession(for:)` sets it:

```swift
private func makeSession(context: AssistantContext,
                         includeSpotlight: Bool = false) throws -> LanguageModelSession {
    // ... existing availability check ...
    let instructions = Self.instructions(for: context)
    var tools: [any Tool] = []
    if includeSpotlight {
        tools.append(SpotlightSearchTool(configuration: .init(
            sources: [.coreSpotlight],
            guide: .init(level: .focused(.items), format: .compact))))
    }
    if let editBridge, let contentGraph {
        tools.append(ApplyEditTool(bridge: editBridge, siteID: context.siteID,
                                   contextSelector: context.selectedElementSelector))
        tools.append(SearchContentTool(contentGraph: contentGraph, siteID: context.siteID))
    }
    return tools.isEmpty
        ? LanguageModelSession(instructions: instructions)
        : LanguageModelSession(tools: tools, instructions: instructions)
}
```

`conversationSession(for:)` calls `makeSession(context: context, includeSpotlight: true)`. The
one-shot `generate`/`generateStructured` paths call `makeSession(context:)` unchanged — they
keep their existing behavior (edit/search pair when deps present, no Spotlight). The
edit/search pair's attachment is *not* touched by this task; only Spotlight is added.

Note: `makeSession` throws `AssistantError.unavailable` *before* constructing any tool, so
`SpotlightSearchTool` is only ever built on a device where the model runs.

### 3. `capabilities.supportsTools` → unconditionally `true`

The `converse` session now always carries at least Spotlight, so the conversational assistant
always supports tools. `supportsTools` drops its `editBridge != nil && contentGraph != nil`
expression and becomes `true`. (`supportsTools` is informational — no app code branches on it.)

### 4. `attachedToolNames`

Reported in the `.started` event (emitted only on the `converse` path). Always include a
Spotlight label; add the edit/search names only when those dependencies are present:

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

## Why conversational-path-only

The `converse` session is the only place retrieval helps, and it is the only place that pays
the guide's token cost. One-shot `generate`/`generateStructured` (alt-text, summaries,
structured metadata) are constrained, single-purpose calls that never search — keeping them
tool-free preserves their full 4,096-token budget for the actual generation. This revises an
earlier "attach to every session" draft, which was abandoned once the guide's real token cost
on the tiny on-device window was measured.

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

In `Tests/AnglesiteCoreTests/FoundationModelAssistantTests.swift` (and the matching
`FoundationModelAssistantToolWiringTests` in `OnDeviceToolsTests.swift`):

- Update `onDeviceCapabilities`: `#expect(!caps.supportsTools)` → `#expect(caps.supportsTools)`.
- Add a test: an assistant built with **no** `editBridge`/`contentGraph` still reports
  `supportsTools == true` (the `converse` path always carries Spotlight).
- Update the existing tool-wiring assertions to the new contract: `supportsTools == true` in
  all dependency configurations, and `attachedToolNames`/`.started` lists begin with
  `"spotlightSearch"`.

These read `capabilities`, which is `nonisolated` and never touches `SystemLanguageModel`, so
they run on any toolchain ≥6.4 without the model.

### Tier 2 — Device-only budget-fit smoke (guarded by `modelAvailable()`, skips on CI)

The regression this task exists to prevent is the 13k-token overflow. A guarded live test
drives `converse` (the Spotlight-carrying path) on a no-deps assistant with a trivial prompt
and asserts the turn reaches `.turnComplete` — i.e. the `.focused`/`.compact` guide fits the
4,096-token budget. This is **not** redundant with the existing live `converse` lifecycle
test: it specifically guards the configuration-fits-budget property that the default config
violated. (The one-shot live `generate`/`generateStructured` tests also keep passing, since
those paths now carry no Spotlight tool.)

### Tier 3 — Manual

True end-to-end RAG ("what did I write about SwiftUI last month?") — verifying the model
actually *retrieves* indexed content — belongs in the Phase C manual smoke, alongside B.6/D.5.
The comprehensive automated suite is #161's scope.

**Net:** #158 lands the wiring + Tier-1 capability tests + a guarded Tier-2 budget-fit smoke,
and explicitly does not claim to verify tool *invocation* on CI — avoiding a silently-skipping
test that would read as green coverage when it is not.

## Out of scope

- The other macOS 27 built-in tools (`OCRTool`, `BarcodeReaderTool`).
- `FileSource`-configured Spotlight search over sandbox file paths.
- The full Phase C test suite (#161) and the Phase C manual smoke.
