# Design: On-device tools — `ApplyEditTool` + `SearchContentTool` (#156, C.6)

**Date:** 2026-06-13
**Issue:** #156 — On-device tools: `ApplyEditTool` + `SearchContentTool`
**Parent:** #134 (Siri AI Phase C — Foundation Models for on-device intelligence)
**Depends on:** #155 (`FoundationModelAssistant`), #154 (`@Generable` types), `SiteContentGraph` (A.1), `IntentEditBridge` (A.4)

## Goal

Give the on-device Foundation Models session two `Tool` conformances so the ~3B model can,
without any network call, **search the current site's content** and **apply structured edits**
back into the app's edit pipeline. Together they form a local agentic loop: the model can look up
a page, then edit it, inside a single `LanguageModelSession`.

## Scope decision

Full integration (not tool-types-only): the two tools are delivered **and** wired into
`FoundationModelAssistant`, flipping `supportsTools` to `true` when the tool dependencies are
present. The existing one-shot `ContentAssistant` API (`generate` / `generateStructured`) is
**not** changed — Foundation Models runs the tool-call loop internally during
`streamResponse`/`respond`, so attaching tools to the session is the only wiring required.

## Architecture

Two new files in `Sources/AnglesiteCore/`, both gated behind `#if compiler(>=6.4)` (the same
toolchain guard used by `FoundationModelAssistant.swift` / `GenerableTypes.swift` / `ContentAssistant.swift`
— `FoundationModels` is absent from CI's `macos-15` runner at runtime, #128):

- `ApplyEditTool.swift`
- `SearchContentTool.swift`

### Dependency injection into `FoundationModelAssistant`

```swift
public init(
    tier: FoundationModelTier = .onDevice,
    editBridge: IntentEditBridge? = nil,
    contentGraph: SiteContentGraph? = nil
)
```

- Both deps are **optional**. When absent, behavior is exactly today's tool-less session.
- `capabilities.supportsTools` is computed: `editBridge != nil && contentGraph != nil`
  (honest per-instance — `capabilities` stays a `nonisolated var` reading stored `let`s).
- `makeSession(context:)` constructs the tools **per call**, capturing `context.siteID` and
  `context.selectedElementSelector`, and only passes `tools:` when both deps exist:

  ```swift
  private func makeSession(context: AssistantContext) throws -> LanguageModelSession {
      // ... availability check unchanged ...
      let instructions = Self.instructions(for: context)
      if let editBridge, let contentGraph {
          let tools: [any Tool] = [
              ApplyEditTool(bridge: editBridge, siteID: context.siteID,
                            contextSelector: context.selectedElementSelector),
              SearchContentTool(contentGraph: contentGraph, siteID: context.siteID),
          ]
          return LanguageModelSession(tools: tools, instructions: instructions)
      }
      return LanguageModelSession(instructions: instructions)
  }
  ```

Apple's built-in `.spotlight` tool (shown in the issue's snippet) is **deferred to C.8 / #158**
(Local RAG: Spotlight search wiring); this task ships only the two app-owned tools.

## `ApplyEditTool`

```swift
struct ApplyEditTool: Tool {
    let name = "applyEdit"
    let description = "Apply a structured edit to an element on a page of the current site."
    typealias Arguments = GeneratedEditCommand   // reuse the #154 @Generable vocabulary

    let bridge: IntentEditBridge
    let siteID: String
    let contextSelector: JSONValue?              // captured from AssistantContext per session

    func call(arguments: GeneratedEditCommand) async throws -> ToolOutput
}
```

Reusing the existing `GeneratedEditCommand` (#154) as `Arguments` keeps a single edit vocabulary
(`filePath` / `selector` / `operation` / `value` / `explanation`) with no duplication.

`call(...)` performs three mappings, then routes through the bridge:

1. **Operation → op string.** `EditOperation` case → `EditMessage.Op` constant:
   - `.replaceText`      → `EditMessage.Op.replaceText`      (`"replace-text"`)
   - `.replaceAttr`      → `EditMessage.Op.replaceAttr`      (`"replace-attr"`)
   - `.replaceImageSrc`  → `EditMessage.Op.replaceImageSrc`  (`"replace-image-src"`)
   - `.applyInstruction` → `EditMessage.Op.applyInstruction` (`"apply-instruction"`)

   This is the case→string bridge the #154 `EditOperation` doc-comment explicitly deferred to #156.

2. **Selector resolution (hybrid).** The plugin's `server/selector.mjs.buildSelector(info)` requires
   a structured `ElementInfo` object (`{tag, classes, nthChild, dataAnglesiteId?, ...}`); there is no
   raw-CSS passthrough. So:
   - `contextSelector` present → use it verbatim (the real overlay `ElementInfo`).
   - else if `arguments.selector` is a **bare tag** (matches `^[A-Za-z][A-Za-z0-9]*$`) → build a
     minimal `ElementInfo`: `{"tag": <lowercased>, "classes": [], "nthChild": 1}`
     (mirrors `selectorPart`'s `tag:nth-child(n)` fallback).
   - else → return a **failure `ToolOutput`** ("Couldn't identify which element to edit — select one
     in the preview, or name a simple tag like `h1`."). No fabricated complex selectors; the bridge
     is **not** called.

3. **Value.** Wrap `arguments.value` (a `String`) as `JSONValue.string(...)` for `EditMessage.value`.
   For `.applyInstruction`, the value is the natural-language instruction.

Then `await bridge.applyEdit(siteID:filePath:selector:op:value:)` and translate the returned
`EditReply` (`.applied` / `.failed` + `message`) into the `ToolOutput` the model reads back. The
bridge already returns a `.failed` reply with an explanatory message when no router is available
for the site; that message is surfaced verbatim.

## `SearchContentTool`

```swift
struct SearchContentTool: Tool {
    let name = "searchContent"
    let description = "Search the current site's pages and posts by title, route, slug, or tag."

    @Generable
    struct Arguments {
        @Guide(description: "What to search for — words from a page title, route, post slug, or tag.")
        var query: String
    }

    let contentGraph: SiteContentGraph
    let siteID: String

    func call(arguments: Arguments) async throws -> ToolOutput
}
```

`call(...)`:
1. `await contentGraph.searchPages(siteID:matching: arguments.query)`
2. `await contentGraph.searchPosts(siteID:matching: arguments.query)`
3. Format a compact, model-readable text block, e.g.:
   ```
   PAGE  /about            (src/pages/about.md)
   POST  my-first-post [draft]  (src/posts/my-first-post.md)
   ```
4. **Empty results → an explicit "No matching pages or posts." line**, never an empty string.
5. **Cap at 20 results** (pages + posts combined) with a `+N more` trailer when truncated, so a
   large site can't blow the small on-device context window. The cap is documented in the output
   trailer (not a silent truncation).

## Error handling

- Tool `call` returns a **descriptive `ToolOutput`** on failure rather than throwing — the model
  should be able to recover within the loop (re-search, change approach, or report to the user). A
  thrown error would abort the whole generation.
- The only thrown path remains genuine session setup failure (`AssistantError.unavailable`),
  already handled in `makeSession`.

## Testing (~6, `AnglesiteCoreTests`)

Use the **real** `SiteContentGraph` actor (preloaded via `upsertPage` / `upsertPost`) and the
**real** `IntentEditBridge` wired to a **fake `EditRouter`** that returns canned `EditReply`s and
records the `EditMessage` it received.

1. `SearchContentTool` finds a page by title and formats it.
2. `SearchContentTool` no-match / empty query → "No matching pages or posts." output.
3. `ApplyEditTool` **with** context selector → routes using that `ElementInfo`; assert the fake
   router received the correctly mapped op string (e.g. `"replace-text"`) and `.string` value.
4. `ApplyEditTool` **no** context, bare-tag selector → builds the minimal `ElementInfo`
   (`{tag, classes:[], nthChild:1}`); assert the routed selector.
5. `ApplyEditTool` **no** context, complex selector (`"p:nth-of-type(2)"`) → graceful failure
   `ToolOutput`; assert the router was **never** called.
6. `ApplyEditTool` router returns `.failed` → the failure message is surfaced in the `ToolOutput`.

Optionally (capability assertion, may fold into an existing suite): `FoundationModelAssistant`
constructed **with** both deps reports `capabilities.supportsTools == true`; **without** them,
`false`.

## Verify-against-SDK note

The exact `FoundationModels.Tool` surface — `ToolOutput`'s initializer, whether `name`/`description`
are stored `let`s vs. computed, and the `includesSchemaInInstructions` requirement — will be
confirmed against the installed SDK during implementation rather than trusted from memory. The
shapes above are the design intent and may need minor signature tweaks to compile.

## Branch / coordination

This is **single-repo** — no plugin change is required, because `ApplyEditTool` adapts to the
plugin's existing `ElementInfo` selector schema rather than extending it. #156 stacks on the
#154/#155 work (C.4/C.5); land those first (or branch #156 off them).

## Out of scope (explicitly)

- Apple's `.spotlight` built-in tool → C.8 / #158.
- Vision / alt-text generation → C.7 / #157.
- Surfacing tools in the chat UI / MAS chat pane → C.9 / #159.
- A model-tier picker in Settings → C.10 / #160.
