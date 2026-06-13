# `@Generable` types + `FoundationModelAssistant` — design

**Date:** 2026-06-13
**Issues:** #154 (C.4 — `@Generable` types), #155 (C.5 — `FoundationModelAssistant` )
**Parent:** #134 (Siri AI Phase C — Foundation Models for on-device intelligence)
**Depends on:** #151 (C.1 — `ContentAssistant` protocol, landed)

## Goal

Give the on-device path a structured-output vocabulary and a concrete `ContentAssistant`
backend. #154 defines the `@Generable` result types the app can act on reliably; #155
implements the actor that streams text and produces those types via Apple's
`FoundationModels` guided generation. Shipped together so the types get a real consumer
and the live tests exercise the full path.

## Constraints

- **Toolchain gating.** `FoundationModels` ships in the macOS 26 SDK but is absent at
  *runtime* on GitHub's `macos-15` CI runner — linking it makes the whole test bundle fail
  to `dlopen`. Everything that imports it is gated behind `#if compiler(>=6.4)` (Xcode 27 /
  Swift 6.4), matching the existing pattern in `ContentAssistant.swift` / `ClaudeAssistant.swift`
  (see #128). Both new source files and both new test files live entirely behind this gate.
- **No PCC session knob.** The public `FoundationModels` framework is on-device. There is no
  caller-selectable "use Private Cloud Compute" session; PCC is used transparently by some
  system APIs. We model a tier abstraction honestly rather than fake a PCC path.

## #154 — `Sources/AnglesiteCore/GenerableTypes.swift`

Entire file behind `#if compiler(>=6.4)` + `import FoundationModels`. Five `@Generable`
types, each field annotated with `@Guide(description:)` so the model fills them reliably.

1. **`GeneratedEditCommand`**
   - `filePath: String`
   - `selector: String`
   - `operation: EditOperation` — `@Generable` enum mirroring `EditMessage.Op` exactly:
     `replaceText`, `replaceAttr`, `replaceImageSrc`, `applyInstruction`. Tied to the real edit
     pipeline vocabulary so a generated command maps onto it without translation.
   - `value: String`
   - `explanation: String`
2. **`GeneratedPageMeta`** — `title: String`, `description: String`, `slug: String`, `tags: [String]`
3. **`GeneratedAltText`** — `altText: String`, `isDecorative: Bool`
4. **`ContentSummary`** — `summary: String`, `wordCount: Int`, `readingTimeMinutes: Int`, `topics: [String]`
5. **`ContentClassification`** — `@Generable` enum: `blogPost`, `landingPage`, `documentation`,
   `portfolio`, `other(String)`

## #155 — `Sources/AnglesiteCore/FoundationModelAssistant.swift`

`public actor FoundationModelAssistant: ContentAssistant`, entire file behind `#if compiler(>=6.4)`.

### Tier model

```swift
public enum FoundationModelTier: Sendable {
    case onDevice            // SystemLanguageModel.default — 3B, free, no network
    case privateCloudCompute // reserved; v1 backs this with the same on-device session
}
```

`.privateCloudCompute` is **modeled now, backed identically for v1**. This lets `ChatModel`
and the #160 tier picker express intent today without misrepresenting capability. Doc
comments state the reality explicitly.

### Construction

`init(tier: FoundationModelTier = .onDevice)`. Builds a **fresh** `LanguageModelSession` over
`SystemLanguageModel.default` per call (in `makeSession`), so each request reflects its own
`AssistantContext` — the base `ContentAssistant` API is one-shot and carries no cross-call
session-persistence contract, so caching would answer later calls with stale page context.

### Surface

- **`generate(prompt:context:)`** → wraps `session.streamResponse(to:)`, yielding text
  deltas into the `AsyncThrowingStream`. `AssistantContext` (page route, current content)
  is folded into the prompt / session instructions.
- **`generateStructured(prompt:context:resultType:)`** → `session.respond(to:generating: T.self).content`.
- **`capabilities`** → `supportsStreaming: true`, `supportsStructuredOutput: true`,
  `supportsVision: false`, `supportsTools: false`. `maxContextTokens` and `providerName`
  vary by tier: `4096` / "On-Device" vs `32768` / "Private Cloud Compute".

### Error handling (maps to `AssistantError`)

- **Model unavailable** — check `SystemLanguageModel.default.availability` before use; if
  `.unavailable`, throw `AssistantError.unavailable(...)` with a message pointing the user to
  **System Settings → Apple Intelligence**.
- **PCC without iCloud+** — since v1 backs PCC with the on-device session anyway, this
  degrades to on-device with a logged warning rather than a hard error (the issue's
  "fall back to on-device with warning"; same outcome, simpler given the framework reality).

## Testing

`GenerableTypesTests.swift` and `FoundationModelAssistantTests.swift`, both entirely behind
`#if compiler(>=6.4)` so CI compiles/loads neither. Each live test guards on availability
and skips gracefully when the on-device model isn't present:

```swift
guard case .available = SystemLanguageModel.default.availability else {
    throw XCTSkip("Apple Intelligence model unavailable on this host")
}
```

(or the Swift Testing early-return / `withKnownIssue` equivalent matching the sibling suites).

**Coverage (~13 tests):**

- **#154 round-trips (~5):** for each of the 5 types, a live `generateStructured` against a
  fixture prompt, asserting the parsed result has sane non-empty fields / correct enum case.
- **#155 assistant (~8):** `generate` streams non-empty text; `generateStructured` returns the
  right type; `capabilities` differ correctly by tier; PCC-tier construction logs the fallback
  and still works; availability-unavailable surfaces `AssistantError.unavailable` with the
  Settings-pointing message; cancel / reset behave.

These are **live-model tests, not mocks**. The proper mock `LanguageModel` session lands with
#104; #161 (C.11 test suite) can retrofit these onto it later. A
`// TODO(#104/#161): migrate to mock session` marker tracks this.

## Out of scope

- Mock `LanguageModel` session (#104) and the consolidated Phase C suite (#161).
- Wiring `FoundationModelAssistant` into `ChatModel` routing / the #160 tier picker.
- The on-device feature tools (#156) and vision/alt-text pipeline (#157) that consume these types.
