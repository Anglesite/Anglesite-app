# C.11 — Phase C Test Suite (Audit + Gap-Fill)

**Issue:** [#161](https://github.com/Anglesite/Anglesite-app/issues/161) · **Parent:** #134 (Phase C) · **Date:** 2026-06-17

## Goal

Confirm Phase C (Foundation Models for on-device intelligence) has comprehensive, honest test
coverage, and close #161. Phase C's tests landed incrementally during C.1–C.10, so the
checklist in #161 is **already largely satisfied**. This task is therefore an *audit* that
maps every checklist item to the tests that satisfy it, plus a single confirmed gap-fill —
not a bulk test-writing effort. Padding tests to hit nominal counts would be the
green-coverage theater this project guards against.

## Audit method

For each #161 checklist item, locate the covering test(s) and classify them:

- **CI** — runs under `swift test` on CI with no model (pure logic / capability reads).
- **Live** — guarded by `modelAvailable()`; runs on a host with Apple Intelligence, no-ops on CI.
- **XCTest** — covered by an XCTest holdout suite (deliberate; see CLAUDE.md / #74).
- **App-target** — logic in the `AnglesiteApp` target, not reachable by `swift test`; the
  testable substance was already extracted into `AnglesiteCore` types that *are* covered.
- **Deferred** — intentionally out of scope, tracked elsewhere.

## Coverage map

| # | #161 checklist item | Covering tests | Class |
|---|---|---|---|
| 1 | `FoundationModelAssistantTests`: generate, generateStructured, streaming (~8) | `FoundationModelAssistantTests.swift` (18 `@Test`): `onDeviceCapabilities`, `pccCapabilities`, `spotlightMakesToolsUnconditional` (CI); `generateStreamsText`, `generateStructuredReturnsType`, `converseEmitsLifecycleEvents`, `converseRemembersAcrossTurns`, `cancelMidStreamYieldsCancelled`, … (Live) | CI + Live |
| 2 | `@Generable` round-trip per struct (~5) | `GenerableTypesTests.swift` (5 `@Test`): `GeneratedEditCommand`, `GeneratedPageMeta`, `GeneratedAltText`, `ContentSummary`, `ContentClassification` | Live |
| 3 | `ApplyEditTool` + `SearchContentTool` with fakes (~6) | `OnDeviceToolsTests.swift` (12 `@Test`) via `FakeEditRouter` + in-memory `SiteContentGraph` | CI |
| 4 | `ChatModel` protocol migration: works with the `ClaudeAssistant` wrapper | `ContentAssistantTests.swift` (7 `@Test`, `StubAssistant`), `ClaudeAssistantTests.swift` (4 `@Test`) — the `ContentAssistant`/`ConversationalAssistant` seam `ChatModel` depends on | CI (protocol); App-target (`ChatModel` glue) |
| 5 | `ChatModel` + `FoundationModelAssistant`: streaming + tool-calling smoke | Streaming accumulation extracted to `ConversationTranscriptTests.swift` (27 `@Test`, CI); FM streaming/tool turns in `FoundationModelAssistantTests` converse tests (Live). `ChatModel`'s own event-loop orchestration is thin glue in the app target | CI + Live; App-target (glue) |
| 6 | Alt-text: mock image → `GeneratedAltText` (~2) | `AltTextGeneratorTests.swift` (8 `@Test`) | CI + Live |
| 7 | Settings: model tier switch resets conversation | Tier persistence: `AppSettingsTests.swift` `foundationModelTierDefaultsToOnDevice`, `foundationModelTierRoundTrip`, `foundationModelTierUnknownFallsBack` (CI). Session reset: `FoundationModelAssistantTests.resetSessionIsSafe` (Live-adjacent). `ChatModel.resetConversation()` calling `assistant.resetSession()` on tier change is app-target glue | CI; App-target (glue) |

Supporting (not a checklist line but Phase C): `ChatHistoryStoreTests.swift` (11 XCTest cases,
the chat persistence layer) — **XCTest**.

### Items intentionally not given new CI tests

- **`ChatModel`-the-type** (items 4, 5, 7 glue). `ChatModel` lives in `AnglesiteApp`; hosted app
  tests are blocked on CI (CLAUDE.md). Its testable substance was already pushed into
  `AnglesiteCore` (`ConversationTranscript`, `ChatHistoryStore`, the assistant protocols) and is
  covered there. The remaining glue (wiring the event stream into `@Observable` state, calling
  `resetSession()` on tier switch) is verified manually / by the app build, consistent with the
  `DeployModel`→`TokenOnboarding` precedent.
- **Mock `LanguageModel` seam.** The `FoundationModelAssistantTests` `TODO(#104/#161)` proposes
  swapping the guarded-live tests for a deterministic mock session. That is tied to **#104**
  (App Intents Testing) and is deferred there to avoid duplicating its work.

## The one gap-fill

`ApplyEditTool.opString(for:)` (`ApplyEditTool.swift:83`) maps all four `EditOperation` cases
to their `EditMessage.Op` strings, but `OnDeviceToolsTests.swift:28`
(`usesContextSelectorAndMapsOp`) asserts only `.replaceText` → `"replace-text"`. The other
three mappings (`.replaceAttr` → `"replace-attr"`, `.replaceImageSrc` → `"replace-image-src"`,
`.applyInstruction` → `"apply-instruction"`) are unverified. This is the op-vocabulary bridge
between #154 (`EditOperation`) and #156 (`ApplyEditTool`) — a real, CI-testable, pure-logic
behavior with a coverage hole.

**Fill:** add one parameterized `@Test(arguments:)` over all four
`(EditOperation, expected op string)` pairs that drives `ApplyEditTool.call(arguments:)`
through a `FakeEditRouter` and asserts `router.received?.op`. To avoid asserting the same
mapping in two places, **remove the lone `#expect(msg?.op == "replace-text")` line from
`usesContextSelectorAndMapsOp`** (`OnDeviceToolsTests.swift:46`); that test keeps its
selector / value / path / output assertions, which the new test does not cover. The new test
becomes the single source of truth for op-string mapping across all cases.

## Testing / verification

- The new parameterized test runs under `swift test` with no model (it uses `FakeEditRouter`,
  not `LanguageModelSession`).
- Full `swift test` (under `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`)
  stays green across all three bundles.

## Out of scope

- Migrating XCTest holdouts to Swift Testing (#74).
- The mock `LanguageModel` session (#104).
- Any `AnglesiteApp`-target test host.
- New Phase C product behavior — this is coverage only.
