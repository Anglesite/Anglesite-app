# App: Siri NL edit interpreter + dry-run diff confirmation — Implementation Plan (Plan B of 2, #251)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the Siri `EditContentIntent` into interpret → dry-run → confirm → apply: on-device Foundation Models turns a spoken instruction into a concrete plugin op (text / attribute / style), a non-mutating `dry_run` sources a before/after preview, and the edit applies only after the user confirms.

**Architecture:** The plugin half (Plan A, released as **v1.2.0**) added `dry_run` + the `edit-style` op. This plan is the app consumer. Foundation Models interpretation is split into a **plain, CI-testable** `InterpretedEdit` + op-mapping (no FM dependency) behind an `EditInterpreting` protocol, and a **`#if compiler(>=6.4)`-gated** FM-backed implementation — mirroring how `AltTextGenerator` keeps logic testable without the live model. `dry_run` threads through a new `EditMessage.dryRun` field and a new `EditReply.Status.preview`.

**Tech Stack:** Swift 6.4 / SwiftUI (Xcode 27), App Intents, Foundation Models, Swift Testing. App repo at `/Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/251-siri-edit-diff` (this worktree, branch `worktree-251-siri-edit-diff`).

## Global Constraints

- App repo worktree: `/Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/251-siri-edit-diff`. Run all commands there.
- Build/test: `swift test --package-path .` with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` (the CommandLineTools swift is too old — see memory). Focused: `swift test --filter <SuiteName>`.
- **Foundation Models is absent at runtime on CI** — all code importing `FoundationModels` or referencing `@Generable`/`Generable` types MUST be inside `#if compiler(>=6.4)`. CI runs `AnglesiteCoreTests` on the older toolchain; `AnglesiteIntentsTests` is only compiled under `compiler(>=6.4)`.
- **CI-testable logic must NOT reference FM types.** The op-mapping (kind → plugin op + value) operates on a plain `InterpretedEdit` (no `@Generable`), so it compiles + tests on CI.
- `dry_run` is the single source of the confirmation's before/after; the app never re-derives it.
- Retire the free-form `apply-instruction` op — the app always emits a concrete op (`replace-text` / `replace-attr` / `edit-style`).
- Confirmation dialogs are spoken aloud by Siri: phrasing is one-line, before/after truncated with an ellipsis.
- Decline must perform **zero apply calls** (the dry-run, being read-only, may already have run).
- Existing callers of `IntentEditBridge.applyEdit` / `EditMessage` / `MCPApplyEditRouter` must be unaffected (new params default to the current behavior).
- The plugin is bundled from the local sibling checkout via `scripts/copy-plugin.sh` (no version pin); the released **v1.2.0** work is on the plugin's `main`. e2e tests need `ANGLESITE_PLUGIN_PATH` + node.

---

### Task 1: `EditMessage.dryRun` + `EditReply.preview` + router parsing

**Files:**
- Modify: `Sources/AnglesiteCore/EditMessage.swift` (add `dryRun` field + emit in `jsonValue`)
- Modify: `Sources/AnglesiteCore/EditRouter.swift` (add `.preview` status + `before`/`after`/`op` fields to `EditReply`)
- Modify: `Sources/AnglesiteCore/MCPApplyEditRouter.swift` (parse `anglesite:edit-preview`)
- Test: `Tests/AnglesiteCoreTests/MCPApplyEditRouterPreviewTests.swift` (create)

**Interfaces:**
- Produces:
  - `EditMessage.init(..., dryRun: Bool = false)` and a `dryRun` stored property; `jsonValue` includes `"dry_run": .bool(true)` only when `dryRun == true`.
  - `EditReply.Status.preview`; `EditReply` gains `before: String?`, `after: String?`, `op: String?` (all default `nil`).
  - `MCPApplyEditRouter` returns an `EditReply` with `status: .preview`, `before`, `after`, `op`, `file` when the tool body is `anglesite:edit-preview`.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/MCPApplyEditRouterPreviewTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("MCPApplyEditRouter edit-preview parsing")
struct MCPApplyEditRouterPreviewTests {
    @Test("parseStructured recognizes an edit-preview body")
    func parsesPreview() throws {
        let body = #"{"type":"anglesite:edit-preview","id":"1","file":"src/pages/about.astro","range":{"start":0,"end":40},"op":"edit-style","before":"<h1>Hi</h1>","after":"<h1 class=\"ang-abc123\">Hi</h1>\n<style>\n  .ang-abc123 { color: teal; }\n</style>"}"#
        let parsed = MCPApplyEditRouter.parsePreview(body)
        #expect(parsed != nil)
        #expect(parsed?.file == "src/pages/about.astro")
        #expect(parsed?.op == "edit-style")
        #expect(parsed?.before == "<h1>Hi</h1>")
        #expect(parsed?.after.contains("color: teal") == true)
    }

    @Test("EditMessage.jsonValue includes dry_run only when set")
    func dryRunSerialization() {
        let off = EditMessage(id: "1", type: .applyEdit, path: "/a/", selector: .object([:]), op: "replace-text", value: .string("x"))
        let on = EditMessage(id: "1", type: .applyEdit, path: "/a/", selector: .object([:]), op: "replace-text", value: .string("x"), dryRun: true)
        guard case .object(let offObj) = off.jsonValue, case .object(let onObj) = on.jsonValue else { Issue.record("not objects"); return }
        #expect(offObj["dry_run"] == nil)
        #expect(onObj["dry_run"] == .bool(true))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter MCPApplyEditRouterPreviewTests`
Expected: FAIL — `parsePreview` undefined, `dryRun:` param missing.

- [ ] **Step 3: Add `dryRun` to `EditMessage`**

In `Sources/AnglesiteCore/EditMessage.swift`, add a stored property `public let dryRun: Bool`, a defaulted init param `dryRun: Bool = false`, and in `jsonValue` after the existing fields:

```swift
        if dryRun { obj["dry_run"] = .bool(true) }
```

(Add `self.dryRun = dryRun` in the init. Leave `decode(from:)` unchanged — the JS→native overlay path never sets dry_run; default false is correct.)

- [ ] **Step 4: Extend `EditReply`**

In `Sources/AnglesiteCore/EditRouter.swift`, add to `EditReply.Status`:

```swift
        case applied, failed, ambiguous, preview
```

Add stored properties (after `result`):

```swift
    /// Preview-only: the source fragment before/after the would-be change (`.preview` status).
    public let before: String?
    public let after: String?
    /// The op the preview/apply was for (e.g. "edit-style"). `nil` outside preview.
    public let op: String?
```

Extend the init with `before: String? = nil, after: String? = nil, op: String? = nil` and assign them.

- [ ] **Step 5: Parse `edit-preview` in the router**

In `Sources/AnglesiteCore/MCPApplyEditRouter.swift`, add a static parser + a branch in `apply`. Add:

```swift
    struct PreviewParsed: Equatable {
        let file: String?
        let op: String?
        let before: String
        let after: String
    }

    static func parsePreview(_ text: String) -> PreviewParsed? {
        guard !text.isEmpty,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["type"] as? String) == "anglesite:edit-preview",
              let before = json["before"] as? String,
              let after = json["after"] as? String
        else { return nil }
        return PreviewParsed(file: json["file"] as? String, op: json["op"] as? String, before: before, after: after)
    }
```

In `apply(_:)`, after computing `text` and BEFORE the existing `.applied` construction, add:

```swift
        if let preview = Self.parsePreview(text) {
            return EditReply(id: message.id, status: .preview, message: nil,
                             file: preview.file, before: preview.before, after: preview.after, op: preview.op)
        }
```

(The `onEdit`/`postProcess` hooks must NOT fire for a preview — they stay below this early return, in the `.applied` path only.)

- [ ] **Step 6: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter MCPApplyEditRouterPreviewTests`
Expected: PASS.

- [ ] **Step 7: Run the AnglesiteCore suite for regressions**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter AnglesiteCoreTests`
Expected: PASS (existing EditReply/EditMessage/router tests unaffected — new fields default to nil/false).

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteCore/EditMessage.swift Sources/AnglesiteCore/EditRouter.swift Sources/AnglesiteCore/MCPApplyEditRouter.swift Tests/AnglesiteCoreTests/MCPApplyEditRouterPreviewTests.swift
git commit -m "feat(edit): EditMessage.dryRun + EditReply.preview + router edit-preview parsing"
```

---

### Task 2: `IntentEditBridge` dry-run pass-through

**Files:**
- Modify: `Sources/AnglesiteCore/IntentEditBridge.swift` (thread `dryRun` into the `EditMessage`)
- Test: `Tests/AnglesiteCoreTests/IntentEditBridgeDryRunTests.swift` (create)

**Interfaces:**
- Consumes: `EditMessage.dryRun` (Task 1).
- Produces: `IntentEditBridge.applyEdit(siteID:filePath:selector:op:value:dryRun:)` — new trailing `dryRun: Bool = false` param, set on the constructed `EditMessage`.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/IntentEditBridgeDryRunTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("IntentEditBridge dry-run")
struct IntentEditBridgeDryRunTests {
    actor Recorder: EditRouter {
        private(set) var messages: [EditMessage] = []
        func apply(_ message: EditMessage) async -> EditReply {
            messages.append(message)
            return EditReply(id: message.id, status: .preview, message: nil, before: "a", after: "b", op: message.op)
        }
    }

    @Test("applyEdit forwards dryRun to the EditMessage")
    func forwardsDryRun() async {
        let rec = Recorder()
        let bridge = IntentEditBridge(routerProvider: { _ in rec }, makeID: { "fixed" })
        _ = await bridge.applyEdit(siteID: "s", filePath: "/a/", selector: .object(["tag": .string("h1")]),
                                   op: "edit-style", value: .object(["property": .string("color"), "value": .string("teal")]),
                                   dryRun: true)
        let sent = await rec.messages
        #expect(sent.count == 1)
        #expect(sent.first?.dryRun == true)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter IntentEditBridgeDryRunTests`
Expected: FAIL — `applyEdit` has no `dryRun:` param.

- [ ] **Step 3: Add the param**

In `Sources/AnglesiteCore/IntentEditBridge.swift`, add `dryRun: Bool = false` as the last param of `applyEdit(...)`, and pass it to the `EditMessage(...)` it constructs (set `dryRun: dryRun`).

- [ ] **Step 4: Run to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter IntentEditBridgeDryRunTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/IntentEditBridge.swift Tests/AnglesiteCoreTests/IntentEditBridgeDryRunTests.swift
git commit -m "feat(edit): IntentEditBridge.applyEdit dryRun pass-through"
```

---

### Task 3: `InterpretedEdit` + op-mapping (plain, CI-testable)

**Files:**
- Create: `Sources/AnglesiteCore/InterpretedEdit.swift`
- Test: `Tests/AnglesiteCoreTests/InterpretedEditTests.swift`

**Interfaces:**
- Produces (NO FoundationModels dependency — must compile on the CI toolchain):
  - `public enum InterpretedEditKind: String, Sendable, Equatable { case text, attribute, style }`
  - `public struct InterpretedEdit: Sendable, Equatable { kind; newText: String?; attributeName: String?; attributeValue: String?; styleProperty: String?; styleValue: String?; summary: String }`
  - `public struct ResolvedEditOp: Sendable, Equatable { let op: String; let value: JSONValue }`
  - `InterpretedEdit.resolveOp() -> ResolvedEditOp?` mapping: `.text`→`("replace-text", .string(newText))`; `.attribute`→`("replace-attr", .object(["name":…,"value":…]))`; `.style`→`("edit-style", .object(["property":…,"value":…]))`. Returns `nil` if the required payload fields for the kind are missing/empty.
  - `public protocol EditInterpreting: Sendable { func interpret(instruction: String, element: InterpretedElementContext) async throws -> InterpretedEdit }`
  - `public struct InterpretedElementContext: Sendable, Equatable { tag: String; currentText: String?; pagePath: String; displayName: String }`

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/InterpretedEditTests.swift`:

```swift
import Testing
@testable import AnglesiteCore

@Suite("InterpretedEdit op-mapping")
struct InterpretedEditTests {
    @Test("text maps to replace-text")
    func text() {
        let e = InterpretedEdit(kind: .text, newText: "Hello", attributeName: nil, attributeValue: nil, styleProperty: nil, styleValue: nil, summary: "s")
        #expect(e.resolveOp() == ResolvedEditOp(op: "replace-text", value: .string("Hello")))
    }
    @Test("attribute maps to replace-attr {name,value}")
    func attribute() {
        let e = InterpretedEdit(kind: .attribute, newText: nil, attributeName: "alt", attributeValue: "Logo", styleProperty: nil, styleValue: nil, summary: "s")
        #expect(e.resolveOp() == ResolvedEditOp(op: "replace-attr", value: .object(["name": .string("alt"), "value": .string("Logo")])))
    }
    @Test("style maps to edit-style {property,value}")
    func style() {
        let e = InterpretedEdit(kind: .style, newText: nil, attributeName: nil, attributeValue: nil, styleProperty: "color", styleValue: "teal", summary: "s")
        #expect(e.resolveOp() == ResolvedEditOp(op: "edit-style", value: .object(["property": .string("color"), "value": .string("teal")])))
    }
    @Test("missing payload yields nil")
    func missing() {
        let e = InterpretedEdit(kind: .text, newText: nil, attributeName: nil, attributeValue: nil, styleProperty: nil, styleValue: nil, summary: "s")
        #expect(e.resolveOp() == nil)
        let e2 = InterpretedEdit(kind: .style, newText: nil, attributeName: nil, attributeValue: nil, styleProperty: "color", styleValue: "", summary: "s")
        #expect(e2.resolveOp() == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter InterpretedEditTests`
Expected: FAIL — types undefined.

- [ ] **Step 3: Implement `InterpretedEdit.swift`**

Create `Sources/AnglesiteCore/InterpretedEdit.swift`:

```swift
import Foundation

/// The kind of change a natural-language instruction resolves to. Plain (no FoundationModels
/// dependency) so the op-mapping compiles + tests on the CI toolchain.
public enum InterpretedEditKind: String, Sendable, Equatable {
    case text, attribute, style
}

/// A model-independent representation of an interpreted edit. The FM-backed interpreter (gated
/// behind `#if compiler(>=6.4)`) produces this; the op-mapping below is pure and CI-tested.
public struct InterpretedEdit: Sendable, Equatable {
    public let kind: InterpretedEditKind
    public let newText: String?
    public let attributeName: String?
    public let attributeValue: String?
    public let styleProperty: String?
    public let styleValue: String?
    /// One-line human phrasing of the change, for the confirmation dialog.
    public let summary: String

    public init(kind: InterpretedEditKind, newText: String?, attributeName: String?, attributeValue: String?,
                styleProperty: String?, styleValue: String?, summary: String) {
        self.kind = kind; self.newText = newText
        self.attributeName = attributeName; self.attributeValue = attributeValue
        self.styleProperty = styleProperty; self.styleValue = styleValue; self.summary = summary
    }

    /// Map to the concrete plugin op + value, or nil if the kind's required payload is missing.
    public func resolveOp() -> ResolvedEditOp? {
        switch kind {
        case .text:
            guard let t = newText, !t.isEmpty else { return nil }
            return ResolvedEditOp(op: "replace-text", value: .string(t))
        case .attribute:
            guard let n = attributeName, !n.isEmpty, let v = attributeValue else { return nil }
            return ResolvedEditOp(op: "replace-attr", value: .object(["name": .string(n), "value": .string(v)]))
        case .style:
            guard let p = styleProperty, !p.isEmpty, let v = styleValue, !v.isEmpty else { return nil }
            return ResolvedEditOp(op: "edit-style", value: .object(["property": .string(p), "value": .string(v)]))
        }
    }
}

public struct ResolvedEditOp: Sendable, Equatable {
    public let op: String
    public let value: JSONValue
    public init(op: String, value: JSONValue) { self.op = op; self.value = value }
}

/// Context about the onscreen element the instruction targets.
public struct InterpretedElementContext: Sendable, Equatable {
    public let tag: String
    public let currentText: String?
    public let pagePath: String
    public let displayName: String
    public init(tag: String, currentText: String?, pagePath: String, displayName: String) {
        self.tag = tag; self.currentText = currentText; self.pagePath = pagePath; self.displayName = displayName
    }
}

/// Seam between the intent and the on-device model. The live implementation is FM-backed and
/// `#if compiler(>=6.4)`-gated; tests inject a fake returning a canned `InterpretedEdit`.
public protocol EditInterpreting: Sendable {
    func interpret(instruction: String, element: InterpretedElementContext) async throws -> InterpretedEdit
}

/// Thrown when on-device interpretation can't run (Apple Intelligence unavailable, etc.).
public enum EditInterpretationError: Error, Sendable, Equatable {
    case unavailable(String)
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter InterpretedEditTests`
Expected: PASS (all four cases).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/InterpretedEdit.swift Tests/AnglesiteCoreTests/InterpretedEditTests.swift
git commit -m "feat(edit): InterpretedEdit + CI-testable op-mapping + EditInterpreting seam"
```

---

### Task 4: FM-backed interpreter (gated)

**Files:**
- Create: `Sources/AnglesiteCore/FoundationModelEditInterpreter.swift` (entirely inside `#if compiler(>=6.4)`)
- Test: `Tests/AnglesiteCoreTests/FoundationModelEditInterpreterTests.swift` (gated `#if compiler(>=6.4)`)

**Interfaces:**
- Consumes: `EditInterpreting`, `InterpretedEdit`, `InterpretedElementContext` (Task 3); the existing `FoundationModelAssistant` / `ContentAssistant.generateStructured(prompt:context:resultType:)` and `AssistantContext` (follow `AltTextGenerator.swift` for the exact call shape and the closure-injection test seam).
- Produces: `FoundationModelEditInterpreter: EditInterpreting`, constructed with an injected `generate` closure (so tests don't need the live model), plus a `@Generable struct GeneratedInterpretedEdit` used only for the model call and mapped to `InterpretedEdit`. Maps the model's availability failure to `EditInterpretationError.unavailable`.

- [ ] **Step 1: Write the failing test (gated)**

Create `Tests/AnglesiteCoreTests/FoundationModelEditInterpreterTests.swift`:

```swift
#if compiler(>=6.4)
import Testing
@testable import AnglesiteCore

@Suite("FoundationModelEditInterpreter")
struct FoundationModelEditInterpreterTests {
    @Test("maps a generated style edit to InterpretedEdit")
    func mapsStyle() async throws {
        let gen = GeneratedInterpretedEdit(kind: .style, newText: "", attributeName: "", attributeValue: "",
                                           styleProperty: "color", styleValue: "teal", summary: "Set color to teal")
        let interp = FoundationModelEditInterpreter(generate: { _, _ in gen })
        let out = try await interp.interpret(
            instruction: "make it teal",
            element: InterpretedElementContext(tag: "h1", currentText: "Hi", pagePath: "/about/", displayName: "h1 — Hi"))
        #expect(out.kind == .style)
        #expect(out.styleProperty == "color")
        #expect(out.styleValue == "teal")
        #expect(out.resolveOp()?.op == "edit-style")
    }

    @Test("propagates unavailability")
    func unavailable() async {
        let interp = FoundationModelEditInterpreter(generate: { _, _ in throw EditInterpretationError.unavailable("nope") })
        await #expect(throws: EditInterpretationError.self) {
            _ = try await interp.interpret(instruction: "x",
                element: InterpretedElementContext(tag: "h1", currentText: nil, pagePath: "/", displayName: "h1"))
        }
    }
}
#endif
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter FoundationModelEditInterpreterTests`
Expected: FAIL — types undefined. (If the local toolchain is < 6.4 the suite is skipped; this plan assumes Xcode 27.)

- [ ] **Step 3: Implement the gated interpreter**

Create `Sources/AnglesiteCore/FoundationModelEditInterpreter.swift`. Model the structure on `AltTextGenerator.swift` (closure injection for testability). Full content:

```swift
#if compiler(>=6.4)
import Foundation
import FoundationModels

/// Structured output the on-device model fills. Mapped to the plain `InterpretedEdit` so the
/// op-mapping stays FM-independent and CI-testable.
@Generable
public struct GeneratedInterpretedEdit: Equatable, Sendable {
    @Guide(description: "The kind of change: text (replace the element's visible text), attribute (set an HTML attribute like alt or href), or style (a CSS property like color or font-size).")
    public var kind: InterpretedEditKindGen
    @Guide(description: "For a text edit: the full new visible text. Empty otherwise.")
    public var newText: String
    @Guide(description: "For an attribute edit: the attribute name (e.g. alt, href). Empty otherwise.")
    public var attributeName: String
    @Guide(description: "For an attribute edit: the new attribute value. Empty otherwise.")
    public var attributeValue: String
    @Guide(description: "For a style edit: the CSS property (e.g. color, font-size). Empty otherwise.")
    public var styleProperty: String
    @Guide(description: "For a style edit: the CSS value (e.g. teal, 2rem). Empty otherwise.")
    public var styleValue: String
    @Guide(description: "One short sentence describing the change, shown to the user before they confirm.")
    public var summary: String
}

@Generable
public enum InterpretedEditKindGen: String, Equatable, Sendable {
    case text, attribute, style
}

/// FM-backed `EditInterpreting`. The `generate` closure is injected so unit tests can supply a
/// canned `GeneratedInterpretedEdit` without the live model; the production initializer wires it
/// to `FoundationModelAssistant.generateStructured` and maps an unavailable model to
/// `EditInterpretationError.unavailable`.
public struct FoundationModelEditInterpreter: EditInterpreting {
    public typealias Generate = @Sendable (_ instruction: String, _ element: InterpretedElementContext) async throws -> GeneratedInterpretedEdit
    private let generate: Generate

    public init(generate: @escaping Generate) { self.generate = generate }

    /// Production wiring. Builds a prompt from the instruction + element context and asks the
    /// on-device model for a `GeneratedInterpretedEdit`. Follow `AltTextGenerator` for the exact
    /// `FoundationModelAssistant.generateStructured(prompt:context:resultType:)` + AssistantContext
    /// call; surface `AssistantError.unavailable` as `EditInterpretationError.unavailable`.
    public init(assistant: FoundationModelAssistant, siteID: String, siteDirectory: URL) {
        self.generate = { instruction, element in
            let prompt = Self.buildPrompt(instruction: instruction, element: element)
            let ctx = AssistantContext(siteID: siteID, siteDirectory: siteDirectory)
            do {
                return try await assistant.generateStructured(prompt: prompt, context: ctx, resultType: GeneratedInterpretedEdit.self)
            } catch let e as AssistantError {
                throw EditInterpretationError.unavailable(String(describing: e))
            }
        }
    }

    public func interpret(instruction: String, element: InterpretedElementContext) async throws -> InterpretedEdit {
        let g = try await generate(instruction, element)
        let kind: InterpretedEditKind = {
            switch g.kind { case .text: return .text; case .attribute: return .attribute; case .style: return .style }
        }()
        return InterpretedEdit(
            kind: kind,
            newText: g.newText.isEmpty ? nil : g.newText,
            attributeName: g.attributeName.isEmpty ? nil : g.attributeName,
            attributeValue: g.attributeValue.isEmpty ? nil : g.attributeValue,
            styleProperty: g.styleProperty.isEmpty ? nil : g.styleProperty,
            styleValue: g.styleValue.isEmpty ? nil : g.styleValue,
            summary: g.summary)
    }

    static func buildPrompt(instruction: String, element: InterpretedElementContext) -> String {
        var lines = [
            "Interpret this edit instruction for a website element.",
            "Element: <\(element.tag)>" + (element.currentText.map { " with text \"\($0)\"" } ?? ""),
            "Page: \(element.pagePath)",
            "Instruction: \(instruction)",
            "Choose exactly one kind (text / attribute / style) and fill only that kind's fields.",
        ]
        return lines.joined(separator: "\n")
    }
}
#endif
```

> **Implementer note:** verify the exact `AssistantContext` initializer and `generateStructured` signature against `AltTextGenerator.swift` / `FoundationModelAssistant.swift`; adjust the production `init` to match. The closure-injected `init(generate:)` is what the tests use and must stay stable. If `AssistantContext` needs more fields, thread them through this `init` — do not call the live model from the test path. NEVER cancel a live `streamResponse` (known trap); `generateStructured` is a single-shot `respond(to:generating:)`, so no cancellation is involved here.

- [ ] **Step 4: Run to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter FoundationModelEditInterpreterTests`
Expected: PASS.

- [ ] **Step 5: Build the whole package to confirm gating is correct**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build --package-path .`
Expected: builds (no FM symbols leak outside the gate).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/FoundationModelEditInterpreter.swift Tests/AnglesiteCoreTests/FoundationModelEditInterpreterTests.swift
git commit -m "feat(edit): Foundation Models NL edit interpreter (gated, injectable)"
```

---

### Task 5: `ContentDialogs.editConfirmation` before/after overload

**Files:**
- Modify: `Sources/AnglesiteIntents/EditContentIntent.swift` (add overload in the `ContentDialogs` extension)
- Test: `Tests/AnglesiteIntentsTests/EditConfirmationDialogTests.swift` (create)

**Interfaces:**
- Consumes: `InterpretedEdit`, `EditReply` (`before`/`after`).
- Produces: `ContentDialogs.editConfirmation(edit: InterpretedEdit, pagePath: String, before: String?, after: String?) -> String` — spoken-friendly per kind, truncating long before/after.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteIntentsTests/EditConfirmationDialogTests.swift`:

```swift
import Testing
import AnglesiteCore
@testable import AnglesiteIntents

@Suite("editConfirmation before/after overload")
struct EditConfirmationDialogTests {
    @Test("text edit reads as a from→to change")
    func text() {
        let e = InterpretedEdit(kind: .text, newText: "Welcome to my studio", attributeName: nil, attributeValue: nil, styleProperty: nil, styleValue: nil, summary: "shorter heading")
        let s = ContentDialogs.editConfirmation(edit: e, pagePath: "/about/", before: "Welcome to my site", after: "Welcome to my studio")
        #expect(s.contains("Welcome to my site"))
        #expect(s.contains("Welcome to my studio"))
        #expect(s.contains("/about/"))
    }
    @Test("style edit reads as set property to value")
    func style() {
        let e = InterpretedEdit(kind: .style, newText: nil, attributeName: nil, attributeValue: nil, styleProperty: "color", styleValue: "teal", summary: "teal")
        let s = ContentDialogs.editConfirmation(edit: e, pagePath: "/about/", before: nil, after: nil)
        #expect(s.contains("color"))
        #expect(s.contains("teal"))
    }
    @Test("long before/after is truncated")
    func truncates() {
        let long = String(repeating: "x", count: 400)
        let e = InterpretedEdit(kind: .text, newText: long, attributeName: nil, attributeValue: nil, styleProperty: nil, styleValue: nil, summary: "s")
        let s = ContentDialogs.editConfirmation(edit: e, pagePath: "/a/", before: long, after: long)
        #expect(s.contains("…"))
        #expect(s.count < 400)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter EditConfirmationDialogTests`
Expected: FAIL — overload undefined.

- [ ] **Step 3: Implement the overload**

In `Sources/AnglesiteIntents/EditContentIntent.swift`, in the `extension ContentDialogs`, add:

```swift
    /// Before/after confirmation summary (#251). Spoken-friendly per kind; long fragments are
    /// truncated so Siri doesn't read paragraphs. Sourced from the plugin dry-run preview.
    public static func editConfirmation(edit: InterpretedEdit, pagePath: String, before: String?, after: String?) -> String {
        func clip(_ s: String, _ n: Int = 60) -> String { s.count <= n ? s : String(s.prefix(n)) + "…" }
        switch edit.kind {
        case .text:
            if let b = before, let a = after {
                return "Change the text from “\(clip(b))” to “\(clip(a))” on \(pagePath)?"
            }
            return "Change the text to “\(clip(edit.newText ?? ""))” on \(pagePath)?"
        case .attribute:
            let name = edit.attributeName ?? "attribute"
            return "Change \(name) to “\(clip(edit.attributeValue ?? ""))” on \(pagePath)?"
        case .style:
            return "Set \(edit.styleProperty ?? "style") to \(clip(edit.styleValue ?? "")) on \(pagePath)?"
        }
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter EditConfirmationDialogTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIntents/EditContentIntent.swift Tests/AnglesiteIntentsTests/EditConfirmationDialogTests.swift
git commit -m "feat(intents): editConfirmation before/after overload (#251 diff)"
```

---

### Task 6: `EditContentIntent.perform` rewrite + interpreter/confirmation seams

**Files:**
- Modify: `Sources/AnglesiteIntents/EditContentIntent.swift` (rewrite `perform`, add `@Dependency` interpreter + TaskLocal seams)
- Create: `Sources/AnglesiteIntents/EditInterpreterOverride.swift` and `Sources/AnglesiteIntents/ConfirmationOverride.swift` (TaskLocal seams)
- Modify: `Sources/AnglesiteIntents/Bootstrap.swift` (register the interpreter dependency)
- Test: covered in Task 7.

**Interfaces:**
- Consumes: `EditInterpreting`, `InterpretedEdit.resolveOp()`, `IntentEditBridge.applyEdit(..., dryRun:)`, `EditReply.preview`, `ContentDialogs.editConfirmation(edit:pagePath:before:after:)`.
- Produces:
  - `EditInterpreterOverride.scoped: (any EditInterpreting)?` (`@TaskLocal`).
  - `ConfirmationDeciding` seam: `ConfirmationOverride.scoped: ConfirmationDecision?` where `enum ConfirmationDecision { case confirm, decline }` (`@TaskLocal`). When set, `perform` uses it instead of `requestConfirmation`; when nil, it calls the real `requestConfirmation` (production).
  - New `perform()` flow: decode selector → interpret (→ unavailable/failed dialog) → resolveOp (→ failed dialog if nil) → dry-run via bridge → (preview failed? failed/ambiguous dialog) → confirm (decline → exit, no apply) → apply → reply dialog.

- [ ] **Step 1: Add the seams**

Create `Sources/AnglesiteIntents/EditInterpreterOverride.swift`:

```swift
import AnglesiteCore

/// Test seam: inject a fake `EditInterpreting` so `perform` doesn't touch the on-device model.
public enum EditInterpreterOverride {
    @TaskLocal public static var scoped: (any EditInterpreting)?
}
```

Create `Sources/AnglesiteIntents/ConfirmationOverride.swift`:

```swift
/// Test seam for the confirmation outcome. `requestConfirmation` is not introspectable under
/// `swift test` (no intentsd / registered app), so the decline-path test drives this instead.
public enum ConfirmationDecision: Sendable { case confirm, decline }

public enum ConfirmationOverride {
    @TaskLocal public static var scoped: ConfirmationDecision?
}
```

- [ ] **Step 2: Rewrite `perform()`**

Replace `EditContentIntent.perform()` body with the interpret→dry-run→confirm→apply flow. Add `@Dependency private var interpreter: any EditInterpreting` to the struct. New body:

```swift
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let bridge = IntentEditBridgeOverride.scoped ?? self.bridge
        let interp = EditInterpreterOverride.scoped ?? self.interpreter
        guard let selector = element.selectorJSON() else {
            return .result(dialog: IntentDialog(stringLiteral: ContentDialogs.editInvalidSelector(displayName: element.displayName)))
        }

        // 1. Interpret the instruction on-device.
        let interpreted: InterpretedEdit
        do {
            interpreted = try await interp.interpret(
                instruction: instruction,
                element: InterpretedElementContext(
                    tag: element.elementTag, currentText: element.currentText,
                    pagePath: element.pagePath, displayName: element.displayName))
        } catch {
            return .result(dialog: IntentDialog(stringLiteral:
                "Editing by voice needs Apple Intelligence, which isn’t available here."))
        }
        guard let resolved = interpreted.resolveOp() else {
            return .result(dialog: IntentDialog(stringLiteral:
                ContentDialogs.editAmbiguous(displayName: element.displayName, detail: nil)))
        }

        // 2. Dry-run: compute the would-be change without writing.
        let preview = await bridge.applyEdit(siteID: element.siteID, filePath: element.pagePath,
                                             selector: selector, op: resolved.op, value: resolved.value, dryRun: true)
        if preview.status != .preview {
            // refusal/ambiguous/failed surfaced by the plugin — relay it, no apply.
            return .result(dialog: IntentDialog(stringLiteral: ContentDialogs.editReply(preview, displayName: element.displayName)))
        }

        // 3. Confirm (decline → exit before apply; tree untouched).
        let decision = ConfirmationOverride.scoped
        if let decision {
            if decision == .decline {
                return .result(dialog: IntentDialog(stringLiteral: "Okay, I won’t change \(element.displayName)."))
            }
        } else {
            try await requestConfirmation(dialog: IntentDialog(stringLiteral:
                ContentDialogs.editConfirmation(edit: interpreted, pagePath: element.pagePath, before: preview.before, after: preview.after)))
        }

        // 4. Apply for real.
        let reply = await bridge.applyEdit(siteID: element.siteID, filePath: element.pagePath,
                                           selector: selector, op: resolved.op, value: resolved.value)
        if reply.status == .failed, reply.message == "canceled" {
            return .result(dialog: IntentDialog(stringLiteral: "Canceled the edit to \(element.displayName)."))
        }
        return .result(dialog: IntentDialog(stringLiteral: ContentDialogs.editReply(reply, displayName: element.displayName)))
    }
```

> **Implementer note:** `ElementEntity` currently exposes `displayName`, `siteID`, `selector`, `pagePath` but NOT a bare `elementTag`/`currentText`. Add lightweight computed accessors on `ElementEntity` that read them from the decoded selector JSON (`tag`, `textContent`) — `element.elementTag` and `element.currentText`. Keep them small and tested in Task 7. If you prefer, decode the selector once in `perform` and pass `tag`/`textContent` from there instead of adding accessors — either is fine, but don't duplicate selector decoding more than once.

- [ ] **Step 3: Register the interpreter dependency**

In `Sources/AnglesiteIntents/Bootstrap.swift`, register a default `any EditInterpreting` alongside `editBridge`. Production wiring: construct a `FoundationModelEditInterpreter` from the app's `FoundationModelAssistant` for the active site (gated `#if compiler(>=6.4)`; on older toolchains register a stub that throws `.unavailable`, so the non-gated library still builds). Follow the existing `AppDependencyManager.shared.add { ... }` pattern used for `editBridge`.

- [ ] **Step 4: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build --package-path .`
Expected: builds. Fix any signature mismatches against the real `ElementEntity`/`AssistantContext`.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIntents/EditContentIntent.swift Sources/AnglesiteIntents/EditInterpreterOverride.swift Sources/AnglesiteIntents/ConfirmationOverride.swift Sources/AnglesiteIntents/Bootstrap.swift Sources/AnglesiteIntents/ElementEntity.swift
git commit -m "feat(intents): EditContentIntent interpret→dry-run→confirm→apply flow"
```

---

### Task 7: Flow tests — confirm, decline, unavailable, dry-run-failure

**Files:**
- Modify/Create: `Tests/AnglesiteIntentsTests/EditContentIntentFlowTests.swift`

**Interfaces:**
- Consumes: `EditInterpreterOverride`, `ConfirmationOverride`, `IntentEditBridgeOverride`, a recording router that distinguishes dry-run vs apply (by `EditMessage.dryRun`).

- [ ] **Step 1: Write the tests**

Create `Tests/AnglesiteIntentsTests/EditContentIntentFlowTests.swift`:

```swift
import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteIntents

@Suite("EditContentIntent interpret→dry-run→confirm→apply")
struct EditContentIntentFlowTests {
    // Router that returns a preview for dry-run calls and an applied reply for real calls,
    // recording each so tests can assert how many of each happened.
    actor PhaseRouter: EditRouter {
        private(set) var dryRuns = 0
        private(set) var applies = 0
        func apply(_ m: EditMessage) async -> EditReply {
            if m.dryRun { dryRuns += 1; return EditReply(id: m.id, status: .preview, message: nil, before: "old", after: "new", op: m.op) }
            applies += 1; return EditReply(id: m.id, status: .applied, message: nil, file: "src/pages/about.astro")
        }
    }
    struct StubInterpreter: EditInterpreting {
        let edit: InterpretedEdit
        func interpret(instruction: String, element: InterpretedElementContext) async throws -> InterpretedEdit { edit }
    }
    struct FailingInterpreter: EditInterpreting {
        func interpret(instruction: String, element: InterpretedElementContext) async throws -> InterpretedEdit {
            throw EditInterpretationError.unavailable("no AI")
        }
    }
    static func textEdit() -> InterpretedEdit {
        InterpretedEdit(kind: .text, newText: "new", attributeName: nil, attributeValue: nil, styleProperty: nil, styleValue: nil, summary: "s")
    }
    static func fixtureIntent() -> EditContentIntent {
        let i = EditContentIntent()
        i.element = ElementEntity(id: "s:element:1", displayName: "h1 — Hi", siteID: "s",
            selector: #"{"tag":"h1","classes":[],"nthChild":1,"textContent":"Hi"}"#, pagePath: "/about/")
        i.instruction = "make it shorter"
        return i
    }
    static func bridge(_ router: EditRouter) -> IntentEditBridge {
        IntentEditBridge(routerProvider: { _ in router }, makeID: { "fixed" })
    }

    @Test("confirm path: one dry-run then one apply")
    func confirmPath() async throws {
        let r = PhaseRouter()
        try await IntentEditBridgeOverride.$scoped.withValue(Self.bridge(r)) {
            try await EditInterpreterOverride.$scoped.withValue(StubInterpreter(edit: Self.textEdit())) {
                try await ConfirmationOverride.$scoped.withValue(.confirm) {
                    _ = try await Self.fixtureIntent().perform()
                }
            }
        }
        #expect(await r.dryRuns == 1)
        #expect(await r.applies == 1)
    }

    @Test("decline path: dry-run happens, apply never does")
    func declinePath() async throws {
        let r = PhaseRouter()
        try await IntentEditBridgeOverride.$scoped.withValue(Self.bridge(r)) {
            try await EditInterpreterOverride.$scoped.withValue(StubInterpreter(edit: Self.textEdit())) {
                try await ConfirmationOverride.$scoped.withValue(.decline) {
                    _ = try await Self.fixtureIntent().perform()
                }
            }
        }
        #expect(await r.dryRuns == 1)
        #expect(await r.applies == 0, "a declined edit must never apply")
    }

    @Test("unavailable interpreter: graceful dialog, zero router calls")
    func unavailable() async throws {
        let r = PhaseRouter()
        try await IntentEditBridgeOverride.$scoped.withValue(Self.bridge(r)) {
            try await EditInterpreterOverride.$scoped.withValue(FailingInterpreter()) {
                try await ConfirmationOverride.$scoped.withValue(.confirm) {
                    _ = try await Self.fixtureIntent().perform()
                }
            }
        }
        #expect(await r.dryRuns == 0)
        #expect(await r.applies == 0)
    }

    @Test("dry-run refusal: relayed, no apply")
    func dryRunRefusal() async throws {
        actor RefusingRouter: EditRouter {
            private(set) var applies = 0
            func apply(_ m: EditMessage) async -> EditReply {
                if m.dryRun { return EditReply(id: m.id, status: .failed, message: "no-match") }
                applies += 1; return EditReply(id: m.id, status: .applied, message: nil)
            }
        }
        let r = RefusingRouter()
        try await IntentEditBridgeOverride.$scoped.withValue(Self.bridge(r)) {
            try await EditInterpreterOverride.$scoped.withValue(StubInterpreter(edit: Self.textEdit())) {
                try await ConfirmationOverride.$scoped.withValue(.confirm) {
                    _ = try await Self.fixtureIntent().perform()
                }
            }
        }
        #expect(await r.applies == 0, "a refused dry-run must not apply")
    }
}
```

- [ ] **Step 2: Run to verify it fails, then passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter EditContentIntentFlowTests`
Expected: initially FAIL if Task 6 accessors aren't in place; PASS once Task 6 is complete. Adjust the `ElementEntity` initializer call in the fixture to match its real signature.

- [ ] **Step 3: Run the whole intents + core suites**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
Expected: PASS. Note any pre-existing unrelated failures (the MCP/apply-edit e2e suites fail without `ANGLESITE_PLUGIN_PATH` + node — set it to run them; otherwise note them as environment-gated, not regressions).

- [ ] **Step 4: Commit**

```bash
git add Tests/AnglesiteIntentsTests/EditContentIntentFlowTests.swift
git commit -m "test(intents): confirm/decline/unavailable/refusal flow for Siri NL edits"
```

---

### Task 8: e2e dry-run against the released plugin + bundled-plugin refresh

**Files:**
- Modify: `Tests/AnglesiteBridgeTests/AppliesEditEndToEndTests.swift` (add a dry-run + edit-style e2e case)

**Interfaces:**
- Consumes: the real plugin (v1.2.0 on `main`) via `MCPApplyEditRouter` + node.

- [ ] **Step 1: Refresh the bundled plugin**

Run: `ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite ./scripts/copy-plugin.sh`
Expected: copies the v1.2.0 plugin (with `dry_run` + `edit-style`) into `Resources/plugin/`.

- [ ] **Step 2: Write the failing e2e test**

In `Tests/AnglesiteBridgeTests/AppliesEditEndToEndTests.swift`, add a case mirroring the existing apply-edit e2e: spin up the MCP server against a temp site whose `src/pages/index.astro` has `<h1 id="t">Welcome</h1>`, send an `EditMessage` with `op: "edit-style"`, `value: .object(["property": .string("color"), "value": .string("teal")])`, `dryRun: true`, and assert the reply `status == .preview`, `after` contains `color: teal`, and the on-disk file is unchanged. Reuse `E2EPrerequisites.locateSiblingPlugin()` / `locateNode()` exactly as the existing test does; skip-or-fail behavior matches the existing suite.

- [ ] **Step 3: Run with prerequisites**

Run: `ANGLESITE_PLUGIN_PATH=/Users/dwk/Developer/github.com/Anglesite/anglesite DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter AppliesEditEndToEndTests`
Expected: PASS (preview returned, file unchanged) — proves the app↔plugin dry-run path end to end against v1.2.0.

- [ ] **Step 4: Commit**

```bash
git add Tests/AnglesiteBridgeTests/AppliesEditEndToEndTests.swift
git commit -m "test(e2e): apply_edit dry_run + edit-style against plugin v1.2.0"
```

---

## Self-Review

**Spec coverage (design doc §1–6 + acceptance table):**
- App-side FM interpreter (§1) → Tasks 3 (plain core) + 4 (FM-backed) ✓
- `perform` interpret→dry-run→confirm→apply (§2, architecture) → Task 6 ✓
- `editConfirmation` before/after overload, spoken-friendly + truncation (§3) → Task 5 ✓
- Plugin `dry_run` consumed; `EditReply.preview` (§4) → Task 1 ✓
- `edit-style` op emitted via op-mapping (§5) → Task 3 `resolveOp` ✓
- `apply-instruction` retired (the new flow never emits it) → Task 6 ✓
- Decline = zero apply (acceptance) → Task 7 `declinePath` ✓
- Dry-run read-only / refusal relayed → Task 7 `dryRunRefusal` + Task 8 e2e ✓
- FM-unavailable graceful, no mutation → Task 6 fallback + Task 7 `unavailable` ✓
- CI-testable op-mapping (constraint) → Task 3 (no FM dependency) ✓

**Placeholder scan:** Task 4 and Task 6 Step 3 contain explicit "implementer note" callouts to verify `AssistantContext`/`generateStructured`/`ElementEntity` signatures against the real code — these are integration seams against existing infra the plan can't fully pin without the live types, not vague TODOs; the testable contracts (closure-injected `init(generate:)`, the seams) are fully specified. All other steps carry complete code.

**Type consistency:** `InterpretedEdit`/`InterpretedEditKind`/`ResolvedEditOp`/`InterpretedElementContext`/`EditInterpreting`/`EditInterpretationError` defined in Task 3 are used with identical signatures in Tasks 4–7. `EditReply.preview` + `before`/`after`/`op` defined in Task 1, consumed in Tasks 5–8. `EditMessage.dryRun` defined Task 1, used in Tasks 2, 7, 8. `ConfirmationDecision`/`ConfirmationOverride`/`EditInterpreterOverride` defined Task 6, used Task 7.

**Risks called out for execution:**
- Exact `AssistantContext` init + `generateStructured` signature must be confirmed against `AltTextGenerator.swift` (Task 4).
- `ElementEntity` accessors for `tag`/`currentText` (Task 6 note) — add small computed props or decode once in `perform`.
- e2e tests require `ANGLESITE_PLUGIN_PATH` + node; on CI they're environment-gated (the existing suite already is).
- `AnglesiteIntentsTests` only compiles under `compiler(>=6.4)` — Tasks 5/7 run locally (Xcode 27), not on CI; the CI-covered logic lives in `AnglesiteCoreTests` (Tasks 1–3).
