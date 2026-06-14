# On-device Tools (`ApplyEditTool` + `SearchContentTool`) Implementation Plan

> ⚠️ **Historical plan — superseded by the shipped code.** The implementation evolved during review:
> the tools return `String` (not `ToolOutput`), `.ambiguous` gets its own message (so the Task 1
> Step 3 snippet's `case .failed, .ambiguous` is stale and would fail the tests), and
> `SearchContentTool` added an empty-query guard, deterministic sorting, and fair per-category cap
> budgeting. **Follow the committed sources in `Sources/AnglesiteCore/` as authoritative**, not the
> snippets below.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two `FoundationModels.Tool` conformances (`ApplyEditTool`, `SearchContentTool`) and wire them into `FoundationModelAssistant`, so the on-device model can search site content and apply structured edits in a local agentic loop with no network calls (#156, C.6).

**Architecture:** Two new struct tools in `AnglesiteCore`, gated behind `#if compiler(>=6.4)` (the toolchain guard already used by `FoundationModelAssistant`/`GenerableTypes` — FoundationModels is absent on CI's runtime, #128). `FoundationModelAssistant` gains optional `IntentEditBridge` + `SiteContentGraph` dependencies; when both are present, `makeSession` attaches the tools and `capabilities.supportsTools` flips to `true`. The one-shot `generate`/`generateStructured` API is untouched — Foundation Models drives the tool loop internally.

**Tech Stack:** Swift 6.4 / Xcode 27, `FoundationModels`, Swift Testing (`@Test`/`@Suite`), SwiftPM (`swift test`).

**Spec:** `docs/specs/2026-06-13-on-device-tools-design.md`

---

## Prerequisites

- Branch `feat/156-on-device-tools` already exists (based on merged `main` containing #154/#155).
- `swift test` needs the Xcode-27 toolchain. Per project memory, prefix with:
  `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`
- The tool `call(...)` methods are pure mapping/routing/query logic — **all tests run without a live model** (no `LanguageModelSession` needed), so they execute on the dev machine wherever `#if compiler(>=6.4)` is satisfied.

## Confirmed API facts (verified against the installed SDK)

- `protocol Tool` requires `name`, `description`, and `func call(arguments:) async throws -> Output`. `parameters` is **defaulted** when `Arguments: Generable`; `name`/`includesSchemaInInstructions` have defaults too. Only provide `name`, `description`, `call`.
- `Output: PromptRepresentable`; **`String` conforms**, so `call` returns `String`.
- `LanguageModelSession(model: .default, tools: [any Tool] = [], instructions: String? = nil)` exists — `LanguageModelSession(tools: tools, instructions: instructions)` compiles.
- `@Generable` synthesizes a memberwise init; reachable from tests via `@testable import AnglesiteCore`.
- `EditMessage.Op` constants: `.replaceText` (`"replace-text"`), `.replaceAttr` (`"replace-attr"`), `.replaceImageSrc` (`"replace-image-src"`), `.applyInstruction` (`"apply-instruction"`).
- `IntentEditBridge.applyEdit(siteID:filePath:selector:op:value:) async -> EditReply`; `EditReply.status` is `.applied | .failed | .ambiguous`, plus `message: String?`.
- `JSONValue` cases: `.null`, `.bool`, `.int`, `.double`, `.string`, `.array([JSONValue])`, `.object([String: JSONValue])`.

## File Structure

- **Create** `Sources/AnglesiteCore/ApplyEditTool.swift` — `ApplyEditTool` struct: `EditOperation→Op` mapping, hybrid selector resolution, routes via `IntentEditBridge`. Gated `#if compiler(>=6.4)`.
- **Create** `Sources/AnglesiteCore/SearchContentTool.swift` — `SearchContentTool` struct: queries `SiteContentGraph`, formats capped text. Gated `#if compiler(>=6.4)`.
- **Modify** `Sources/AnglesiteCore/FoundationModelAssistant.swift` — optional deps in `init`, `capabilities.supportsTools`, tool attachment in `makeSession`.
- **Create** `Tests/AnglesiteCoreTests/OnDeviceToolsTests.swift` — fake `EditRouter`, real `SiteContentGraph`, ~7 tests. Gated `#if compiler(>=6.4)`.

---

## Task 1: `ApplyEditTool` — op mapping + hybrid selector + routing

**Files:**
- Create: `Sources/AnglesiteCore/ApplyEditTool.swift`
- Test: `Tests/AnglesiteCoreTests/OnDeviceToolsTests.swift`

- [ ] **Step 1: Write the failing tests (and the shared fake) for `ApplyEditTool`**

Create `Tests/AnglesiteCoreTests/OnDeviceToolsTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

// Gated like the types under test — FoundationModels is unavailable at runtime on CI (#128).
// These tests need no live model: the tools' `call(...)` is pure mapping/routing/query logic.
#if compiler(>=6.4)
import FoundationModels

/// Records the EditMessage it receives and returns a canned reply.
actor FakeEditRouter: EditRouter {
    private(set) var received: EditMessage?
    private let reply: EditReply
    init(reply: EditReply) { self.reply = reply }
    func apply(_ message: EditMessage) async -> EditReply {
        received = message
        return reply
    }
}

private func makeBridge(_ router: FakeEditRouter) -> IntentEditBridge {
    IntentEditBridge(routerProvider: { _ in router }, makeID: { "test-id" })
}

@Suite("On-device tools: ApplyEditTool")
struct ApplyEditToolTests {

    @Test("context selector is used verbatim; operation maps to the op string; value is wrapped")
    func usesContextSelectorAndMapsOp() async throws {
        let router = FakeEditRouter(reply: EditReply(id: "test-id", status: .applied, message: "ok"))
        let element: JSONValue = .object([
            "tag": .string("h1"), "classes": .array([]), "nthChild": .int(1),
        ])
        let tool = ApplyEditTool(bridge: makeBridge(router), siteID: "site1", contextSelector: element)
        let cmd = GeneratedEditCommand(
            filePath: "src/pages/about.md",
            selector: "ignored-by-tool",
            operation: .replaceText,
            value: "New Title",
            explanation: "rename heading"
        )

        let out = try await tool.call(arguments: cmd)

        let msg = await router.received
        #expect(msg?.op == "replace-text")
        #expect(msg?.selector == element)
        #expect(msg?.value == .string("New Title"))
        #expect(msg?.path == "src/pages/about.md")
        #expect(out.contains("Applied"))
    }

    @Test("no context selector + bare-tag selector builds a minimal ElementInfo")
    func bareTagBuildsMinimalElementInfo() async throws {
        let router = FakeEditRouter(reply: EditReply(id: "test-id", status: .applied, message: nil))
        let tool = ApplyEditTool(bridge: makeBridge(router), siteID: "site1", contextSelector: nil)
        let cmd = GeneratedEditCommand(
            filePath: "src/pages/index.md",
            selector: "H1",
            operation: .replaceAttr,
            value: "hello",
            explanation: "x"
        )

        _ = try await tool.call(arguments: cmd)

        let msg = await router.received
        #expect(msg?.selector == .object([
            "tag": .string("h1"), "classes": .array([]), "nthChild": .int(1),
        ]))
        #expect(msg?.op == "replace-attr")
    }

    @Test("no context selector + complex selector fails gracefully without calling the bridge")
    func complexSelectorFailsGracefully() async throws {
        let router = FakeEditRouter(reply: EditReply(id: "test-id", status: .applied, message: "ok"))
        let tool = ApplyEditTool(bridge: makeBridge(router), siteID: "site1", contextSelector: nil)
        let cmd = GeneratedEditCommand(
            filePath: "src/pages/index.md",
            selector: "p:nth-of-type(2)",
            operation: .replaceText,
            value: "x",
            explanation: "x"
        )

        let out = try await tool.call(arguments: cmd)

        #expect(await router.received == nil)
        #expect(out.contains("Couldn't identify"))
    }

    @Test("a failed reply surfaces its message in the tool output")
    func failedReplySurfacesMessage() async throws {
        let router = FakeEditRouter(reply: EditReply(id: "test-id", status: .failed, message: "no router for this site"))
        let element: JSONValue = .object(["tag": .string("h1"), "classes": .array([]), "nthChild": .int(1)])
        let tool = ApplyEditTool(bridge: makeBridge(router), siteID: "site1", contextSelector: element)
        let cmd = GeneratedEditCommand(
            filePath: "src/pages/about.md", selector: "h1",
            operation: .applyInstruction, value: "make it punchier", explanation: "x"
        )

        let out = try await tool.call(arguments: cmd)

        #expect(out.contains("failed"))
        #expect(out.contains("no router for this site"))
    }
}
#endif
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ApplyEditToolTests`
Expected: FAIL — `cannot find 'ApplyEditTool' in scope`.

- [ ] **Step 3: Implement `ApplyEditTool`**

Create `Sources/AnglesiteCore/ApplyEditTool.swift`:

```swift
import Foundation

// Gated to the Xcode-27 toolchain — FoundationModels is absent at runtime on CI (#128).
// Same pattern as FoundationModelAssistant.swift / GenerableTypes.swift.
#if compiler(>=6.4)
import FoundationModels

/// A FoundationModels ``Tool`` that lets the on-device model apply a structured edit to an element
/// on a page of the current site, routing through ``IntentEditBridge`` (and on to the plugin's
/// edit pipeline). Reuses ``GeneratedEditCommand`` (#154) as its arguments so the model speaks one
/// edit vocabulary.
public struct ApplyEditTool: Tool {
    public let name = "applyEdit"
    public let description = "Apply a structured edit to an element on a page of the current site."

    private let bridge: IntentEditBridge
    private let siteID: String
    /// The structured `ElementInfo` for the element the user selected in the overlay, if any —
    /// taken from `AssistantContext.selectedElementSelector`. Preferred over a model-supplied
    /// selector because it's a real, resolved selector rather than a guess.
    private let contextSelector: JSONValue?

    public init(bridge: IntentEditBridge, siteID: String, contextSelector: JSONValue?) {
        self.bridge = bridge
        self.siteID = siteID
        self.contextSelector = contextSelector
    }

    public func call(arguments: GeneratedEditCommand) async throws -> String {
        guard let selector = resolveSelector(arguments.selector) else {
            return "Couldn't identify which element to edit — select one in the preview, or name a simple tag like h1."
        }
        let reply = await bridge.applyEdit(
            siteID: siteID,
            filePath: arguments.filePath,
            selector: selector,
            op: Self.opString(for: arguments.operation),
            value: .string(arguments.value)
        )
        switch reply.status {
        case .applied:
            return "Applied edit to \(arguments.filePath)." + (reply.message.map { " \($0)" } ?? "")
        case .failed, .ambiguous:
            return "Edit failed: \(reply.message ?? "unknown error")."
        }
    }

    // MARK: Selector resolution (hybrid: context first, bare-tag fallback, else nil)

    /// Resolve the structured `ElementInfo` the plugin's `selector.mjs` requires.
    /// 1. Prefer the overlay-resolved context selector.
    /// 2. Else, if the model's selector is a bare tag (`h1`, `p`), build a minimal ElementInfo.
    /// 3. Else, give up — we don't fabricate complex selectors.
    private func resolveSelector(_ raw: String) -> JSONValue? {
        if let contextSelector { return contextSelector }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isBareTag(trimmed) else { return nil }
        return .object([
            "tag": .string(trimmed.lowercased()),
            "classes": .array([]),
            "nthChild": .int(1),
        ])
    }

    /// A bare HTML tag: letters then alphanumerics, nothing else (no combinators, classes, pseudo).
    private static func isBareTag(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Map the #154 ``EditOperation`` onto the `EditMessage.Op` string vocabulary (the bridge
    /// deferred in `GenerableTypes.swift`'s doc-comment, "TODO(#156)").
    private static func opString(for op: EditOperation) -> String {
        switch op {
        case .replaceText: return EditMessage.Op.replaceText
        case .replaceAttr: return EditMessage.Op.replaceAttr
        case .replaceImageSrc: return EditMessage.Op.replaceImageSrc
        case .applyInstruction: return EditMessage.Op.applyInstruction
        }
    }
}
#endif
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ApplyEditToolTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ApplyEditTool.swift Tests/AnglesiteCoreTests/OnDeviceToolsTests.swift
git commit -m "feat(core): ApplyEditTool — on-device structured edits via IntentEditBridge (#156)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `SearchContentTool` — query + formatted, capped output

**Files:**
- Create: `Sources/AnglesiteCore/SearchContentTool.swift`
- Test: `Tests/AnglesiteCoreTests/OnDeviceToolsTests.swift` (append a suite)

- [ ] **Step 1: Write the failing tests for `SearchContentTool`**

Append inside the `#if compiler(>=6.4)` block in `OnDeviceToolsTests.swift` (before the closing `#endif`):

```swift
@Suite("On-device tools: SearchContentTool")
struct SearchContentToolTests {

    private func makeGraph() async -> SiteContentGraph {
        let graph = SiteContentGraph()
        await graph.upsertPage(.init(
            id: "site1:page:/about", siteID: "site1", route: "/about",
            filePath: "src/pages/about.md", title: "About Us",
            lastModified: Date(timeIntervalSince1970: 0)
        ))
        await graph.upsertPost(.init(
            id: "site1:post:hello", siteID: "site1", collection: "posts", slug: "hello-world",
            title: "Hello World", draft: true, publishDate: nil, tags: ["intro"],
            filePath: "src/posts/hello.md", lastModified: Date(timeIntervalSince1970: 0)
        ))
        return graph
    }

    @Test("finds a page by title and formats it")
    func findsPageByTitle() async throws {
        let tool = SearchContentTool(contentGraph: await makeGraph(), siteID: "site1")
        let out = try await tool.call(arguments: .init(query: "about"))
        #expect(out.contains("PAGE"))
        #expect(out.contains("/about"))
        #expect(out.contains("src/pages/about.md"))
    }

    @Test("marks a draft post and includes its file path")
    func findsDraftPost() async throws {
        let tool = SearchContentTool(contentGraph: await makeGraph(), siteID: "site1")
        let out = try await tool.call(arguments: .init(query: "hello"))
        #expect(out.contains("POST"))
        #expect(out.contains("hello-world"))
        #expect(out.contains("[draft]"))
    }

    @Test("no matches returns an explicit message, not an empty string")
    func noMatchesIsExplicit() async throws {
        let tool = SearchContentTool(contentGraph: await makeGraph(), siteID: "site1")
        let out = try await tool.call(arguments: .init(query: "zzz-no-such-thing"))
        #expect(out == "No matching pages or posts.")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SearchContentToolTests`
Expected: FAIL — `cannot find 'SearchContentTool' in scope`.

- [ ] **Step 3: Implement `SearchContentTool`**

Create `Sources/AnglesiteCore/SearchContentTool.swift`:

```swift
import Foundation

// Gated to the Xcode-27 toolchain — FoundationModels is absent at runtime on CI (#128).
#if compiler(>=6.4)
import FoundationModels

/// A FoundationModels ``Tool`` that lets the on-device model search the current site's pages and
/// posts (by title, route, slug, collection, or tag) via ``SiteContentGraph`` — local RAG with no
/// network call.
public struct SearchContentTool: Tool {
    public let name = "searchContent"
    public let description = "Search the current site's pages and posts by title, route, slug, or tag."

    @Generable
    public struct Arguments {
        @Guide(description: "What to search for — words from a page title, route, post slug, or tag.")
        public var query: String
    }

    /// Largest site without flooding the small on-device context window. Truncation is surfaced
    /// in the output trailer (never silent).
    private static let resultCap = 20

    private let contentGraph: SiteContentGraph
    private let siteID: String

    public init(contentGraph: SiteContentGraph, siteID: String) {
        self.contentGraph = contentGraph
        self.siteID = siteID
    }

    public func call(arguments: Arguments) async throws -> String {
        let pages = await contentGraph.searchPages(siteID: siteID, matching: arguments.query)
        let posts = await contentGraph.searchPosts(siteID: siteID, matching: arguments.query)

        var lines: [String] = []
        for page in pages {
            lines.append("PAGE  \(page.route)  (\(page.filePath))")
        }
        for post in posts {
            let draft = post.draft ? " [draft]" : ""
            lines.append("POST  \(post.slug)\(draft)  (\(post.filePath))")
        }

        if lines.isEmpty { return "No matching pages or posts." }
        if lines.count > Self.resultCap {
            let shown = lines.prefix(Self.resultCap).joined(separator: "\n")
            return shown + "\n… +\(lines.count - Self.resultCap) more (refine your query to narrow results)."
        }
        return lines.joined(separator: "\n")
    }
}
#endif
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SearchContentToolTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SearchContentTool.swift Tests/AnglesiteCoreTests/OnDeviceToolsTests.swift
git commit -m "feat(core): SearchContentTool — on-device site search via SiteContentGraph (#156)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Wire the tools into `FoundationModelAssistant`

**Files:**
- Modify: `Sources/AnglesiteCore/FoundationModelAssistant.swift`
- Test: `Tests/AnglesiteCoreTests/OnDeviceToolsTests.swift` (append a suite)

- [ ] **Step 1: Write the failing capability tests**

Append inside the `#if compiler(>=6.4)` block in `OnDeviceToolsTests.swift` (before the closing `#endif`):

```swift
@Suite("FoundationModelAssistant tool wiring")
struct FoundationModelAssistantToolWiringTests {

    @Test("supportsTools is true only when both dependencies are injected")
    func capabilitiesReflectDeps() async {
        let router = FakeEditRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let bridge = makeBridge(router)
        let graph = SiteContentGraph()

        let withTools = FoundationModelAssistant(tier: .onDevice, editBridge: bridge, contentGraph: graph)
        #expect(withTools.capabilities.supportsTools == true)

        let withoutTools = FoundationModelAssistant(tier: .onDevice)
        #expect(withoutTools.capabilities.supportsTools == false)

        let partial = FoundationModelAssistant(tier: .onDevice, editBridge: bridge, contentGraph: nil)
        #expect(partial.capabilities.supportsTools == false)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter FoundationModelAssistantToolWiringTests`
Expected: FAIL — extra arguments `editBridge`/`contentGraph` in call to `init`.

- [ ] **Step 3: Add the optional dependencies and store them**

In `Sources/AnglesiteCore/FoundationModelAssistant.swift`, replace the stored property + `init` block (currently lines ~31–41):

```swift
    private let tier: FoundationModelTier
    private let editBridge: IntentEditBridge?
    private let contentGraph: SiteContentGraph?
    private let logger = Logger(subsystem: "dev.anglesite.app", category: "FoundationModelAssistant")

    /// `editBridge` + `contentGraph` are optional. When **both** are supplied, the assistant
    /// attaches ``ApplyEditTool`` + ``SearchContentTool`` to each session (a local agentic loop)
    /// and advertises `supportsTools`. When either is `nil`, behavior is the tool-less default.
    public init(
        tier: FoundationModelTier = .onDevice,
        editBridge: IntentEditBridge? = nil,
        contentGraph: SiteContentGraph? = nil
    ) {
        self.tier = tier
        self.editBridge = editBridge
        self.contentGraph = contentGraph
        if tier == .privateCloudCompute {
            // v1 has no separate PCC session; fall back to on-device with a logged warning so the
            // requested tier degrades gracefully rather than erroring (see spec / #155).
            logger.warning("privateCloudCompute tier requested; v1 backs it with the on-device session")
        }
    }
```

- [ ] **Step 4: Make `capabilities.supportsTools` reflect the deps**

In the same file, change the `supportsTools:` line in the `capabilities` computed property (currently `supportsTools: false,`) to:

```swift
            supportsTools: editBridge != nil && contentGraph != nil,
```

(`capabilities` stays a `nonisolated var`; it reads the immutable `Sendable` `let`s, which is allowed from a `nonisolated` context.)

- [ ] **Step 5: Run the capability test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter FoundationModelAssistantToolWiringTests`
Expected: PASS (1 test).

- [ ] **Step 6: Attach the tools in `makeSession`**

In the same file, replace the final `return` of `makeSession(context:)` (currently `return LanguageModelSession(instructions: Self.instructions(for: context))`) with:

```swift
        let instructions = Self.instructions(for: context)
        if let editBridge, let contentGraph {
            let tools: [any Tool] = [
                ApplyEditTool(
                    bridge: editBridge,
                    siteID: context.siteID,
                    contextSelector: context.selectedElementSelector
                ),
                SearchContentTool(contentGraph: contentGraph, siteID: context.siteID),
            ]
            return LanguageModelSession(tools: tools, instructions: instructions)
        }
        return LanguageModelSession(instructions: instructions)
```

- [ ] **Step 7: Run the whole on-device tools suite to verify nothing regressed**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter OnDeviceTools`

(Or run all three suites explicitly: `--filter ApplyEditToolTests --filter SearchContentToolTests --filter FoundationModelAssistantToolWiringTests`.)
Expected: PASS (8 tests total: 4 + 3 + 1).

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteCore/FoundationModelAssistant.swift Tests/AnglesiteCoreTests/OnDeviceToolsTests.swift
git commit -m "feat(core): wire ApplyEditTool + SearchContentTool into FoundationModelAssistant (#156)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Full suite + docs closeout

**Files:**
- Modify: `docs/specs/2026-06-13-on-device-tools-design.md` (correct the verify-against-SDK note)

- [ ] **Step 1: Run the complete test suite**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
Expected: PASS — the pre-existing suite count plus the 8 new tests; no regressions.

- [ ] **Step 2: Update the design doc's "Verify-against-SDK" section to record the resolved API**

In `docs/specs/2026-06-13-on-device-tools-design.md`, replace the body of the
"## Verify-against-SDK note" section with the confirmed facts:

```markdown
## Verify-against-SDK note (resolved)

Confirmed against the macOS 26 SDK during implementation:
- `Tool.call(arguments:) async throws -> Output` where `Output: PromptRepresentable`; `String`
  conforms, so both tools return `String`.
- `Tool` requires only `name`, `description`, `call`; `parameters` is defaulted for
  `Arguments: Generable`.
- `LanguageModelSession(model:tools:instructions:)` accepts `instructions: String?`, so
  `LanguageModelSession(tools:instructions:)` compiles.
```

- [ ] **Step 3: Commit**

```bash
git add docs/specs/2026-06-13-on-device-tools-design.md
git commit -m "docs(specs): record resolved FoundationModels Tool API for #156

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 4: Open the PR**

```bash
git push -u origin feat/156-on-device-tools
gh pr create --title "feat(core): on-device ApplyEditTool + SearchContentTool (#156)" \
  --body "Implements C.6 (#156): two FoundationModels Tool conformances wired into FoundationModelAssistant, forming a local agentic loop (search site content + apply structured edits) with no network calls.

- ApplyEditTool reuses the #154 GeneratedEditCommand; maps EditOperation→EditMessage.Op; hybrid selector resolution (context ElementInfo → bare-tag fallback → graceful failure).
- SearchContentTool queries SiteContentGraph, capped/formatted output.
- FoundationModelAssistant gains optional IntentEditBridge + SiteContentGraph deps; supportsTools reflects them.
- 8 deterministic tests (no live model needed).

Design: docs/specs/2026-06-13-on-device-tools-design.md

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Self-Review

**Spec coverage:**
- Optional dep-injection + `supportsTools` → Task 3. ✅
- `makeSession` attaches tools only when both deps present → Task 3, Step 6. ✅
- `ApplyEditTool` reuses `GeneratedEditCommand`, op mapping, value wrap → Task 1. ✅
- Hybrid selector (context → bare-tag → graceful fail) → Task 1 (3 of 4 tests cover the branches). ✅
- `SearchContentTool` query + formatted + capped + explicit empty → Task 2 (+ cap logic implemented; cap path documented). ✅
- Error-as-output (no throwing) → Task 1/2 `call` returns descriptive `String`. ✅
- ~6 tests with fakes → 8 tests delivered (real graph + fake router). ✅
- `.spotlight`/vision/chat-UI deferrals → out of scope, untouched. ✅

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows complete code. ✅

**Type consistency:** `ApplyEditTool(bridge:siteID:contextSelector:)`, `SearchContentTool(contentGraph:siteID:)`, `SearchContentTool.Arguments(query:)`, `FoundationModelAssistant(tier:editBridge:contentGraph:)`, `EditMessage.Op.*`, `EditReply(id:status:message:)`, `JSONValue.object/.string/.array/.int`, `SiteContentGraph.Page/.Post` inits — all match the verified signatures and are used identically across tasks. ✅

> Note: the cap-truncation path (`> 20` results) has implementation but no dedicated test (kept to the issue's ~6-test budget; the empty + populated paths are covered). Acceptable; add a 21-item test later if the path becomes load-bearing.
