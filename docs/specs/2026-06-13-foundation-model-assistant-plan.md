# `@Generable` types + `FoundationModelAssistant` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the five `@Generable` structured-output types (#154) and the `FoundationModelAssistant` actor (#155) that streams text and produces those types via Apple's on-device `FoundationModels`.

**Architecture:** Both new source files and both new test files are gated entirely behind `#if compiler(>=6.4)` — `FoundationModels` is absent at runtime on CI's `macos-15` runner and linking it crashes the test bundle (#128). The assistant conforms to the existing `ContentAssistant` protocol; a `FoundationModelTier` enum models on-device vs. Private Cloud Compute intent honestly (v1 backs both with the on-device session). Live-model tests skip gracefully when Apple Intelligence is unavailable on the host.

**Tech Stack:** Swift 6.4 / Xcode 27, `FoundationModels` (`SystemLanguageModel`, `LanguageModelSession`, `@Generable`, `@Guide`), Swift Testing (`@Test`/`#expect`/`@Suite`), SwiftPM.

**Spec:** `docs/specs/2026-06-13-foundation-model-assistant-design.md`

**Branch:** `feat/154-155-foundation-model-assistant` (already created off `main`).

---

## Toolchain note for every build/test command

Per repo memory, `swift test`/`swift build` need the Xcode 27 toolchain explicitly:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
```

Prefix the SwiftPM commands below with this (or have it exported in the shell). If `swift test` hangs with no output, a stale `swift-test` process is holding the `.build` lock — `pgrep -fl swift-test` and kill the orphan.

The **CI-meaningful** gate is that the package **compiles on both toolchains** and existing tests stay green. The new live-model `@Test`s only execute on an Xcode-27 host with Apple Intelligence enabled; elsewhere they early-return (skip). Do not treat a skipped live test as a failure.

---

## File structure

- **Create** `Sources/AnglesiteCore/GenerableTypes.swift` — the 5 `@Generable` result types + the `EditOperation` enum. One responsibility: structured-output vocabulary.
- **Create** `Sources/AnglesiteCore/FoundationModelAssistant.swift` — the `ContentAssistant` actor + `FoundationModelTier`.
- **Modify** `Sources/AnglesiteCore/ConversationalAssistant.swift` — add `AssistantError.unavailable(String)`.
- **Create** `Tests/AnglesiteCoreTests/GenerableTypesTests.swift` — round-trip live tests for the 5 types.
- **Create** `Tests/AnglesiteCoreTests/FoundationModelAssistantTests.swift` — assistant behavior + tier/error tests.

---

## Task 1: Add `AssistantError.unavailable`

**Files:**
- Modify: `Sources/AnglesiteCore/ConversationalAssistant.swift:50-57`
- Test: `Tests/AnglesiteCoreTests/ContentAssistantTests.swift` (existing suite; add one `@Test`)

- [ ] **Step 1: Write the failing test**

Add this `@Test` inside the `ContentAssistantTests` struct in `Tests/AnglesiteCoreTests/ContentAssistantTests.swift` (after `messageEquatable`):

```swift
    @Test("AssistantError.unavailable is equatable and carries its message")
    func unavailableErrorEquatable() {
        let a = AssistantError.unavailable("Enable Apple Intelligence")
        #expect(a == AssistantError.unavailable("Enable Apple Intelligence"))
        #expect(a != AssistantError.unavailable("other"))
        #expect(a != AssistantError.unsupported("Enable Apple Intelligence"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter ContentAssistantTests`
Expected: FAIL to **compile** — `type 'AssistantError' has no member 'unavailable'`.

- [ ] **Step 3: Add the enum case**

In `Sources/AnglesiteCore/ConversationalAssistant.swift`, extend the `AssistantError` enum (currently `unsupported` + `streamFailed`):

```swift
public enum AssistantError: Error, Sendable, Equatable {
    case unsupported(String)
    /// Thrown by ``ContentAssistant/generate(prompt:context:)`` when the underlying stream produces
    /// a `.failed` event — i.e. the backend reported an in-band error that `generate()` cannot yield
    /// as a text chunk. Distinct from the in-stream form `AssistantEvent.failed`, which
    /// ``ConversationalAssistant/converse(prompt:context:)`` surfaces as a yielded value (not a throw).
    case streamFailed(String)
    /// The backend's model isn't usable on this host (e.g. Apple Intelligence not enabled, or the
    /// on-device model hasn't finished downloading). The associated message is user-facing and should
    /// direct the user to the fix — for FoundationModels, System Settings → Apple Intelligence.
    case unavailable(String)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter ContentAssistantTests`
Expected: PASS (existing tests in the suite still pass too).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ConversationalAssistant.swift Tests/AnglesiteCoreTests/ContentAssistantTests.swift
git commit -m "feat(core): add AssistantError.unavailable for model-not-ready path (#155)"
```

---

## Task 2: `GenerableTypes.swift` — the five `@Generable` types

**Files:**
- Create: `Sources/AnglesiteCore/GenerableTypes.swift`

No standalone unit test step here: `@Generable` types can't be meaningfully unit-tested without a live model session, so their coverage is the round-trip tests in Task 3. This task's verification is **compilation** on the Xcode-27 toolchain.

- [ ] **Step 1: Create the file**

Create `Sources/AnglesiteCore/GenerableTypes.swift`:

```swift
import Foundation

// `FoundationModels` ships in the macOS 26 SDK but is absent from GitHub's `macos-15`
// runner at *runtime* — linking it into the package makes the whole test bundle fail to
// `dlopen`. Gate it behind the Xcode-27 toolchain (Swift 6.4) so CI on Xcode 26.3 builds
// without it, while production (always Xcode 27) gets these types. See #128 and
// ContentAssistant.swift for the same pattern.
#if compiler(>=6.4)
import FoundationModels

/// The kind of mutation a ``GeneratedEditCommand`` performs. Mirrors the operation vocabulary
/// of the app's edit pipeline (`EditMessage`) so a model-generated command maps onto a real edit
/// without translation.
@Generable
public enum EditOperation: Equatable, Sendable {
    case replaceText
    case setAttribute
    case insertBefore
    case insertAfter
    case remove
}

/// A structured edit the on-device model proposes for a single element. Consumed by the
/// (future) `ApplyEditTool` (#156); `selector` matches the overlay/`IntentEditBridge` selector form.
@Generable
public struct GeneratedEditCommand: Equatable, Sendable {
    @Guide(description: "Path to the source file to edit, relative to the site root, e.g. 'src/pages/about.md'.")
    public var filePath: String

    @Guide(description: "CSS selector or element reference identifying what to edit, e.g. 'h1' or 'p:nth-of-type(2)'.")
    public var selector: String

    @Guide(description: "The kind of edit to perform.")
    public var operation: EditOperation

    @Guide(description: "The new text, attribute value, or markup to apply. Empty for a 'remove' operation.")
    public var value: String

    @Guide(description: "One short sentence explaining the change, shown to the user before they confirm it.")
    public var explanation: String
}

/// SEO/page metadata generated for a page from its content. Consumed by `new-page` flows and #157.
@Generable
public struct GeneratedPageMeta: Equatable, Sendable {
    @Guide(description: "A concise, descriptive page title under 60 characters.")
    public var title: String

    @Guide(description: "A meta description summarizing the page in 150-160 characters.")
    public var description: String

    @Guide(description: "A URL-safe slug in lowercase kebab-case, e.g. 'about-our-team'.")
    public var slug: String

    @Guide(description: "Three to six lowercase topic tags describing the page.")
    public var tags: [String]
}

/// Alt text generated for an image, plus whether the image is purely decorative.
@Generable
public struct GeneratedAltText: Equatable, Sendable {
    @Guide(description: "Descriptive alt text under 125 characters. Empty when the image is decorative.")
    public var altText: String

    @Guide(description: "True if the image is purely decorative and should have empty alt text.")
    public var isDecorative: Bool
}

/// A summary of a piece of content with reading metadata.
@Generable
public struct ContentSummary: Equatable, Sendable {
    @Guide(description: "A two-to-three sentence summary of the content.")
    public var summary: String

    @Guide(description: "Approximate word count of the source content.")
    public var wordCount: Int

    @Guide(description: "Estimated reading time in whole minutes (assume ~200 words per minute).")
    public var readingTimeMinutes: Int

    @Guide(description: "Three to five key topics covered, as short phrases.")
    public var topics: [String]
}

/// What kind of page a piece of content is. Drives layout/metadata defaults.
@Generable
public enum ContentClassification: Equatable, Sendable {
    case blogPost
    case landingPage
    case documentation
    case portfolio
    @Guide(description: "Any other content type, with a short label describing it.")
    case other(String)
}
#endif
```

- [ ] **Step 2: Verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build --package-path .`
Expected: builds with no errors. (On the Xcode-27 toolchain the `#if compiler(>=6.4)` body compiles; the types now exist.)

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteCore/GenerableTypes.swift
git commit -m "feat(core): add @Generable types for guided generation (#154)"
```

---

## Task 3: `GenerableTypesTests.swift` — round-trip live tests

**Files:**
- Create: `Tests/AnglesiteCoreTests/GenerableTypesTests.swift`

These are **live-model** tests: each generates a value from a fixture prompt against the
on-device model and asserts the parsed result is sane. They early-return (skip) when the model
is unavailable, so they only truly execute on an Xcode-27 host with Apple Intelligence enabled.

- [ ] **Step 1: Write the tests**

Create `Tests/AnglesiteCoreTests/GenerableTypesTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

// Gated for the same reason as the types under test — FoundationModels is unavailable at
// runtime on CI (#128). These are live-model round-trip tests; they skip when the on-device
// model isn't present so they never produce spurious CI failures.
// TODO(#104/#161): migrate to the mock LanguageModel session once #104 lands.
#if compiler(>=6.4)
import FoundationModels

@Suite("GenerableTypes round-trips")
struct GenerableTypesTests {

    /// Early-return guard: live tests only run on a host with the on-device model available.
    /// Returns `nil` and the caller should `return` when the model can't be used.
    private func availableSession(instructions: String) -> LanguageModelSession? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        return LanguageModelSession(instructions: instructions)
    }

    @Test("GeneratedEditCommand parses with a known operation")
    func editCommandRoundTrips() async throws {
        guard let session = availableSession(instructions: "You produce a single structured edit command.") else { return }
        let result = try await session.respond(
            to: "Change the <h1> in src/pages/index.md to say 'Welcome'.",
            generating: GeneratedEditCommand.self
        ).content
        #expect(!result.filePath.isEmpty)
        #expect(!result.selector.isEmpty)
        #expect(!result.explanation.isEmpty)
    }

    @Test("GeneratedPageMeta parses with non-empty fields")
    func pageMetaRoundTrips() async throws {
        guard let session = availableSession(instructions: "You produce SEO metadata for a web page.") else { return }
        let result = try await session.respond(
            to: "Generate page metadata for an 'About our bakery' page.",
            generating: GeneratedPageMeta.self
        ).content
        #expect(!result.title.isEmpty)
        #expect(!result.slug.isEmpty)
        #expect(!result.tags.isEmpty)
    }

    @Test("GeneratedAltText parses a boolean and string")
    func altTextRoundTrips() async throws {
        guard let session = availableSession(instructions: "You produce image alt text.") else { return }
        let result = try await session.respond(
            to: "Generate alt text for a photo of a golden retriever running on a beach.",
            generating: GeneratedAltText.self
        ).content
        // A non-decorative photo should produce non-empty alt text.
        #expect(result.isDecorative || !result.altText.isEmpty)
    }

    @Test("ContentSummary parses numeric reading metadata")
    func summaryRoundTrips() async throws {
        guard let session = availableSession(instructions: "You summarize content.") else { return }
        let result = try await session.respond(
            to: "Summarize: 'Our bakery opened in 1998 and specializes in sourdough. We bake fresh daily.'",
            generating: ContentSummary.self
        ).content
        #expect(!result.summary.isEmpty)
        #expect(result.wordCount >= 0)
        #expect(result.readingTimeMinutes >= 0)
    }

    @Test("ContentClassification parses to a known case")
    func classificationRoundTrips() async throws {
        guard let session = availableSession(instructions: "You classify web page content into a category.") else { return }
        let result = try await session.respond(
            to: "Classify this content: 'Posted March 3rd — my thoughts on the new framework release...'",
            generating: ContentClassification.self
        ).content
        // Any well-formed case is acceptable; assert it decoded to one of the enum cases.
        switch result {
        case .blogPost, .landingPage, .documentation, .portfolio, .other:
            #expect(Bool(true))
        }
    }
}
#endif
```

- [ ] **Step 2: Verify the suite compiles and runs (skips or passes)**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter GenerableTypesTests`
Expected: compiles; tests either PASS (model available) or run-and-skip via early return (model unavailable). Neither is a failure. If they error with a FoundationModels API mismatch (e.g. `respond(to:generating:)` signature), fix the call against the installed SDK and re-run.

- [ ] **Step 3: Commit**

```bash
git add Tests/AnglesiteCoreTests/GenerableTypesTests.swift
git commit -m "test(core): round-trip tests for @Generable types (#154)"
```

---

## Task 4: `FoundationModelAssistant.swift` — the actor

**Files:**
- Create: `Sources/AnglesiteCore/FoundationModelAssistant.swift`

Verification is compilation; behavior is covered by Task 5.

- [ ] **Step 1: Create the file**

Create `Sources/AnglesiteCore/FoundationModelAssistant.swift`:

```swift
import Foundation
import OSLog

// Gated to the Xcode-27 toolchain — FoundationModels is absent at runtime on CI (#128).
// See ContentAssistant.swift / ClaudeAssistant.swift for the same pattern.
#if compiler(>=6.4)
import FoundationModels

/// Which Apple model substrate a ``FoundationModelAssistant`` targets.
///
/// - Important: The public `FoundationModels` framework is **on-device**. There is no
///   caller-selectable Private Cloud Compute session; PCC is used transparently by some system
///   APIs. `.privateCloudCompute` is therefore *modeled* here so callers (`ChatModel`, the #160
///   tier picker) can express intent, but **v1 backs it with the same on-device session**. The
///   only observable difference today is the advertised ``AssistantCapabilities``.
public enum FoundationModelTier: Sendable, Equatable {
    /// `SystemLanguageModel.default` — the ~3B on-device model. Free, no network.
    case onDevice
    /// Reserved. Backed by the on-device session in v1 (see type note); advertises a larger
    /// context window via capabilities.
    case privateCloudCompute
}

/// A ``ContentAssistant`` backed by Apple's on-device `FoundationModels`. Streams free-form text
/// and produces ``Generable`` structured output via guided generation.
///
/// Compiled into AnglesiteCore on both build targets (an `#if !ANGLESITE_MAS` guard would be a
/// no-op in the SPM package; see CLAUDE.md). Unlike ``ClaudeAssistant`` it needs no subprocess, so
/// it is the on-device path usable from the sandboxed MAS build.
public actor FoundationModelAssistant: ContentAssistant {
    private let tier: FoundationModelTier
    private let logger = Logger(subsystem: "dev.anglesite.app", category: "FoundationModelAssistant")
    private var session: LanguageModelSession?

    public init(tier: FoundationModelTier = .onDevice) {
        self.tier = tier
        if tier == .privateCloudCompute {
            // v1 has no separate PCC session; fall back to on-device with a logged warning so the
            // requested tier degrades gracefully rather than erroring (see spec / #155).
            logger.warning("privateCloudCompute tier requested; v1 backs it with the on-device session")
        }
    }

    public nonisolated var capabilities: AssistantCapabilities {
        AssistantCapabilities(
            supportsStreaming: true,
            supportsStructuredOutput: true,
            supportsVision: false,
            supportsTools: false,
            maxContextTokens: tier == .privateCloudCompute ? 32_768 : 4_096,
            providerName: tier == .privateCloudCompute ? "Private Cloud Compute" : "On-Device"
        )
    }

    // MARK: ContentAssistant

    public func generate(
        prompt: String,
        context: AssistantContext
    ) async throws -> AsyncThrowingStream<String, Error> {
        let session = try makeSession(context: context)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // `streamResponse` yields cumulative snapshots; diff against the prior prefix
                    // so callers receive incremental deltas (matching the protocol contract).
                    var previous = ""
                    for try await snapshot in session.streamResponse(to: prompt) {
                        let full = snapshot.content
                        if full.count >= previous.count {
                            continuation.yield(String(full.dropFirst(previous.count)))
                        } else {
                            continuation.yield(full) // non-monotonic snapshot; yield as-is
                        }
                        previous = full
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func generateStructured<T: Generable>(
        prompt: String,
        context: AssistantContext,
        resultType: T.Type
    ) async throws -> T {
        let session = try makeSession(context: context)
        return try await session.respond(to: prompt, generating: T.self).content
    }

    public func cancel() { session = nil }
    public func resetSession() { session = nil }

    // MARK: Session

    /// Lazily builds (and caches) a session, throwing ``AssistantError/unavailable(_:)`` when the
    /// on-device model can't be used on this host.
    private func makeSession(context: AssistantContext) throws -> LanguageModelSession {
        if let session { return session }
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable:
            throw AssistantError.unavailable(
                "Apple Intelligence isn't available. Enable it in System Settings → Apple Intelligence & Siri, then try again."
            )
        @unknown default:
            throw AssistantError.unavailable("The on-device model is unavailable on this device.")
        }
        let session = LanguageModelSession(instructions: Self.instructions(for: context))
        self.session = session
        return session
    }

    /// Folds the situational ``AssistantContext`` into session instructions.
    private static func instructions(for context: AssistantContext) -> String {
        var lines = ["You are an assistant helping edit and improve a website."]
        if let route = context.currentPageRoute { lines.append("The user is viewing the page at \(route).") }
        if let content = context.currentPageContent { lines.append("Current page content:\n\(content)") }
        return lines.joined(separator: "\n")
    }
}
#endif
```

- [ ] **Step 2: Verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build --package-path .`
Expected: builds clean. If the `LanguageModelSession` streaming element or `respond(to:generating:)` signature differs in the installed SDK, adjust the two call sites (`streamResponse(to:)` loop and `respond(to:generating:).content`) to match and re-build. The actor's shape, tier logic, and error handling stay as written.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteCore/FoundationModelAssistant.swift
git commit -m "feat(core): FoundationModelAssistant on-device ContentAssistant (#155)"
```

---

## Task 5: `FoundationModelAssistantTests.swift`

**Files:**
- Create: `Tests/AnglesiteCoreTests/FoundationModelAssistantTests.swift`

Capability/tier tests run **everywhere** (no model needed). The `generate`/`generateStructured`
tests are live and early-return when the model is unavailable.

- [ ] **Step 1: Write the tests**

Create `Tests/AnglesiteCoreTests/FoundationModelAssistantTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

// Gated like the type under test (#128). Capability/tier assertions run on any toolchain≥6.4;
// the generate/generateStructured tests are live-model and skip when unavailable.
// TODO(#104/#161): migrate the live tests to the mock LanguageModel session once #104 lands.
#if compiler(>=6.4)
import FoundationModels

@Suite("FoundationModelAssistant")
struct FoundationModelAssistantTests {

    private func makeContext() -> AssistantContext {
        AssistantContext(siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/site"))
    }

    private func modelAvailable() -> Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    // MARK: Capabilities / tier (no model required)

    @Test("on-device tier advertises the on-device capabilities")
    func onDeviceCapabilities() {
        let caps = FoundationModelAssistant(tier: .onDevice).capabilities
        #expect(caps.providerName == "On-Device")
        #expect(caps.maxContextTokens == 4_096)
        #expect(caps.supportsStreaming)
        #expect(caps.supportsStructuredOutput)
        #expect(!caps.supportsTools)
        #expect(!caps.supportsVision)
    }

    @Test("PCC tier advertises a larger context window and PCC provider name")
    func pccCapabilities() {
        let caps = FoundationModelAssistant(tier: .privateCloudCompute).capabilities
        #expect(caps.providerName == "Private Cloud Compute")
        #expect(caps.maxContextTokens == 32_768)
    }

    @Test("default tier is on-device")
    func defaultTierIsOnDevice() {
        #expect(FoundationModelAssistant().capabilities.providerName == "On-Device")
    }

    @Test("PCC-tier assistant constructs and remains usable (falls back to on-device)")
    func pccConstructsAndIsUsable() async {
        // Construction must not throw; the fallback is internal (logged). Capabilities prove the
        // instance is live.
        let assistant = FoundationModelAssistant(tier: .privateCloudCompute)
        #expect(await assistant.capabilities.maxContextTokens == 32_768)
    }

    // MARK: Error path (no model required when the host lacks Apple Intelligence)

    @Test("generate surfaces AssistantError.unavailable when the model is absent")
    func generateUnavailableSurfacesError() async {
        guard !modelAvailable() else { return } // only meaningful on a host without the model
        let assistant = FoundationModelAssistant()
        await #expect(throws: AssistantError.self) {
            _ = try await assistant.generate(prompt: "hi", context: makeContext())
        }
    }

    // MARK: Live paths (skip when the model is unavailable)

    @Test("generate streams non-empty text")
    func generateStreamsText() async throws {
        guard modelAvailable() else { return }
        let assistant = FoundationModelAssistant()
        var collected = ""
        for try await chunk in try await assistant.generate(prompt: "Say hello in one short sentence.", context: makeContext()) {
            collected += chunk
        }
        #expect(!collected.isEmpty)
    }

    @Test("generateStructured returns the requested Generable type")
    func generateStructuredReturnsType() async throws {
        guard modelAvailable() else { return }
        let assistant = FoundationModelAssistant()
        let result = try await assistant.generateStructured(
            prompt: "Generate page metadata for a contact page.",
            context: makeContext(),
            resultType: GeneratedPageMeta.self
        )
        #expect(!result.title.isEmpty)
    }

    @Test("resetSession does not throw and assistant stays usable")
    func resetSessionIsSafe() async throws {
        let assistant = FoundationModelAssistant()
        await assistant.resetSession()
        await assistant.cancel()
        #expect(await assistant.capabilities.providerName == "On-Device")
    }
}
#endif
```

- [ ] **Step 2: Run the suite**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter FoundationModelAssistantTests`
Expected: the four capability/tier tests PASS unconditionally; `resetSessionIsSafe` PASSES; the unavailable-path and live tests PASS or skip depending on host. No failures.

- [ ] **Step 3: Commit**

```bash
git add Tests/AnglesiteCoreTests/FoundationModelAssistantTests.swift
git commit -m "test(core): FoundationModelAssistant capability + live tests (#155)"
```

---

## Task 6: Full build, both schemes, and PR

**Files:** none (verification + PR).

- [ ] **Step 1: Full SwiftPM test run (regression check)**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
Expected: the full suite passes (the live FoundationModels tests skip when the model is unavailable). Confirm no existing test regressed.

- [ ] **Step 2: Build both app schemes**

Run:
```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build
```
Expected: both build succeed. (`FoundationModelAssistant` must compile on the sandboxed MAS target too — it has no subprocess dependency.)

- [ ] **Step 3: Push and open the PR**

```bash
git push -u origin feat/154-155-foundation-model-assistant
gh pr create --title "feat(core): @Generable types + FoundationModelAssistant (#154, #155)" \
  --body "$(cat <<'EOF'
## Summary
- Add five `@Generable` structured-output types: `GeneratedEditCommand` (+`EditOperation`), `GeneratedPageMeta`, `GeneratedAltText`, `ContentSummary`, `ContentClassification` (#154).
- Add `FoundationModelAssistant` actor conforming to `ContentAssistant`, with an honest `FoundationModelTier` model (on-device vs. PCC, both backed by the on-device session in v1) (#155).
- Add `AssistantError.unavailable` for the model-not-ready path, pointing users to System Settings → Apple Intelligence.

## Notes
- All FoundationModels-touching code is gated behind `#if compiler(>=6.4)` so CI's `macos-15` runner builds without the framework (#128).
- Live-model tests skip gracefully when Apple Intelligence is unavailable; capability/tier tests run unconditionally.
- Proper mock `LanguageModel` session is deferred to #104/#161 (marked with TODOs).

Closes #154, #155.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```
Expected: PR opens; CI `build-test` and `JS edit-overlay` checks run.

- [ ] **Step 4: Claim the issues**

```bash
gh issue edit 154 --add-label "status:in-progress"
gh issue edit 155 --add-label "status:in-progress"
```

---

## Self-review notes

- **Spec coverage:** all 5 types (Task 2) ✓; `FoundationModelAssistant` actor, tiers, streaming, structured, capabilities, error handling (Task 4) ✓; round-trip tests (Task 3) ✓; assistant tests incl. tier/error (Task 5) ✓; gating + graceful skip (every task) ✓; on-device fallback for PCC (Task 4) ✓.
- **Type consistency:** `FoundationModelTier` cases (`onDevice`/`privateCloudCompute`), `AssistantError.unavailable(String)`, `generateStructured(prompt:context:resultType:)`, and capability field names (`maxContextTokens`, `providerName`) match across tasks and the existing protocol.
- **Known SDK risk (called out, not a placeholder):** the exact `LanguageModelSession.streamResponse(to:)` snapshot element and `respond(to:generating:)` signature can't be verified without the macOS 26 SDK on this host; Tasks 3–4 instruct the implementer to reconcile the two call sites against the installed SDK if they differ. The actor/type/test structure is complete and final.
