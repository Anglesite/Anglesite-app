# Operation Descriptors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a lean, test-enforced `OperationDescriptor` model + registry that describes each Siri-facing Anglesite operation's side-effect level, confirmation, cancellability, and result shape, so Siri/Shortcuts/system-MCP stay consistent with the real intents.

**Architecture:** A plain value-type model (`OperationDescriptor`, `OperationSideEffect`, `OperationResult`) and a canonical registry (`AnglesiteOperations.all`) in the `AnglesiteIntents` module. Coverage is anchored to `AnglesiteShortcuts` via a co-located `phraseExposedIntentNames` set. Honesty is enforced by a hybrid of data tests (coverage/uniqueness/value-table) and behavioral tests (routing + content-mutation) that reuse the existing fake-service seams.

**Tech Stack:** Swift 6.4 / Xcode 27 (Xcode-beta), Swift Testing (`@Test`/`#expect`), AppIntents.

## Global Constraints

- **Swift Testing only** — no XCTest. New tests live in `extension AppIntentsTests { @Suite(...) struct ... }`, mirroring the existing `AnglesiteIntentsTests` convention. Root suite `AppIntents` is `.serialized`.
- **Model is a plain value type in `AnglesiteIntents`** — no macOS-27-only symbols (it must compile on the Swift 6.3 library target too; only the *test* target is `compiler(>=6.4)`-gated).
- **No production-intent changes** — this issue ships the model + tests only. `Bootstrap.swift` is untouched; no `AnglesiteMCPRegistration`.
- **Run tests with:** `swift test --package-path . --filter OperationDescriptor` from the worktree root `/Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/operation-descriptors`. `xcode-select` already points at `/Applications/Xcode-beta.app`, so no explicit `DEVELOPER_DIR` is needed.
- **Conventional commits**, ending with the `Co-Authored-By` trailer.
- **Spec:** `docs/superpowers/specs/2026-06-19-operation-descriptors-design.md` — the descriptor value table there is authoritative.

## File Structure

- `Sources/AnglesiteIntents/OperationDescriptor.swift` *(create)* — the model types + `AnglesiteOperations` registry. One responsibility: describe operations.
- `Sources/AnglesiteIntents/AnglesiteShortcuts.swift` *(modify)* — add `phraseExposedIntentNames` next to the phrase definitions.
- `Tests/AnglesiteIntentsTests/OperationDescriptorTests.swift` *(create)* — data tests (coverage, sync guard, uniqueness, declared-field value table).
- `Tests/AnglesiteIntentsTests/OperationDescriptorBehavioralTests.swift` *(create)* — behavioral tests (routing agreement, content-mutation agreement) reusing fake seams.

---

### Task 1: Descriptor model, registry, anchor, and data tests

**Files:**
- Create: `Sources/AnglesiteIntents/OperationDescriptor.swift`
- Modify: `Sources/AnglesiteIntents/AnglesiteShortcuts.swift`
- Test: `Tests/AnglesiteIntentsTests/OperationDescriptorTests.swift`

**Interfaces:**
- Produces: `OperationDescriptor` (struct), `OperationSideEffect` (enum: `.readOnly`/`.createsContent`/`.modifiesContent`/`.publishes`), `OperationResult` (enum: `.none`/`.entity(String)`/`.entities(String)`), `AnglesiteOperations.all: [OperationDescriptor]`, `AnglesiteOperations.descriptor(forIntentTypeName:) -> OperationDescriptor?`, `AnglesiteShortcuts.phraseExposedIntentNames: Set<String>`.

- [ ] **Step 1: Write the model + registry**

Create `Sources/AnglesiteIntents/OperationDescriptor.swift`:

```swift
import Foundation

/// A lean, test-enforced description of a Siri-facing Anglesite operation. Captures only what the
/// auto-derived system-MCP schema (`mcpbridge`) cannot express — side-effect level, confirmation,
/// cancellability, and a human-readable result label — so Siri, Shortcuts, and system MCP stay
/// consistent with the real intents without re-declaring parameters (those flow from `@Parameter` /
/// `@Property` via D.2). Spec: docs/superpowers/specs/2026-06-19-operation-descriptors-design.md.
public struct OperationDescriptor: Sendable, Equatable {
    /// Stable slug, e.g. "deploy-site". Unique across the registry.
    public let operationID: String
    /// Human-facing name; matches the intent's `title`, e.g. "Deploy Site".
    public let displayName: String
    /// The intent's Swift type name, e.g. "DeploySiteIntent". The coverage-anchor key; unique.
    public let intentTypeName: String
    public let sideEffect: OperationSideEffect
    public let requiresConfirmation: Bool
    public let isCancellable: Bool
    public let resultShape: OperationResult
    /// The `mcpbridge`-assigned tool name, once Apple's naming convention is pinned (D.5/#166).
    /// `nil` for all current entries — forward-looking, not asserted by any test.
    public let mcpToolName: String?

    public init(
        operationID: String,
        displayName: String,
        intentTypeName: String,
        sideEffect: OperationSideEffect,
        requiresConfirmation: Bool,
        isCancellable: Bool,
        resultShape: OperationResult,
        mcpToolName: String? = nil
    ) {
        self.operationID = operationID
        self.displayName = displayName
        self.intentTypeName = intentTypeName
        self.sideEffect = sideEffect
        self.requiresConfirmation = requiresConfirmation
        self.isCancellable = isCancellable
        self.resultShape = resultShape
        self.mcpToolName = mcpToolName
    }
}

/// Mutation risk to a site's content *source* — what drives confirmation decisions. Operations that
/// spawn subprocesses but don't touch site source (audit, preview, status, search) are `.readOnly`.
public enum OperationSideEffect: Sendable, Equatable {
    case readOnly
    case createsContent
    case modifiesContent
    case publishes
}

/// The shape an agent gets back. The associated string is the entity type name.
public enum OperationResult: Sendable, Equatable {
    case none
    case entity(String)
    case entities(String)
}

/// The canonical registry — the single source of truth for Siri-facing operation metadata.
public enum AnglesiteOperations {
    public static let all: [OperationDescriptor] = [
        OperationDescriptor(
            operationID: "deploy-site", displayName: "Deploy Site",
            intentTypeName: "DeploySiteIntent", sideEffect: .publishes,
            requiresConfirmation: true, isCancellable: true,
            resultShape: .entity("SiteEntity")
        ),
        OperationDescriptor(
            operationID: "backup-site", displayName: "Back Up Site",
            intentTypeName: "BackupSiteIntent", sideEffect: .modifiesContent,
            requiresConfirmation: false, isCancellable: true,
            resultShape: .entity("SiteEntity")
        ),
        OperationDescriptor(
            operationID: "audit-site", displayName: "Check Site",
            intentTypeName: "AuditSiteIntent", sideEffect: .readOnly,
            requiresConfirmation: false, isCancellable: true,
            resultShape: .entity("SiteEntity")
        ),
        OperationDescriptor(
            operationID: "open-site", displayName: "Open Site",
            intentTypeName: "OpenSiteIntent", sideEffect: .readOnly,
            requiresConfirmation: false, isCancellable: false,
            resultShape: .none
        ),
        OperationDescriptor(
            operationID: "search-content", displayName: "Search Site Content",
            intentTypeName: "SearchContentIntent", sideEffect: .readOnly,
            requiresConfirmation: false, isCancellable: false,
            resultShape: .entities("ContentMatchEntity")
        ),
        OperationDescriptor(
            operationID: "site-status", displayName: "Site Content Status",
            intentTypeName: "SiteStatusIntent", sideEffect: .readOnly,
            requiresConfirmation: false, isCancellable: false,
            resultShape: .none
        ),
        OperationDescriptor(
            operationID: "preview-site", displayName: "Preview Site",
            intentTypeName: "PreviewSiteIntent", sideEffect: .readOnly,
            requiresConfirmation: false, isCancellable: false,
            resultShape: .none
        ),
        OperationDescriptor(
            operationID: "add-page", displayName: "Add Page",
            intentTypeName: "AddPageIntent", sideEffect: .createsContent,
            requiresConfirmation: false, isCancellable: true,
            resultShape: .entity("PageEntity")
        ),
        OperationDescriptor(
            operationID: "add-post", displayName: "Add Post",
            intentTypeName: "AddPostIntent", sideEffect: .createsContent,
            requiresConfirmation: false, isCancellable: true,
            resultShape: .entity("PostEntity")
        ),
        OperationDescriptor(
            operationID: "edit-content", displayName: "Edit Content",
            intentTypeName: "EditContentIntent", sideEffect: .modifiesContent,
            requiresConfirmation: false, isCancellable: true,
            resultShape: .none
        ),
    ]

    /// Look up a descriptor by intent type name. `nil` if none registered.
    public static func descriptor(forIntentTypeName name: String) -> OperationDescriptor? {
        all.first { $0.intentTypeName == name }
    }
}
```

- [ ] **Step 2: Add the App Shortcuts anchor list**

In `Sources/AnglesiteIntents/AnglesiteShortcuts.swift`, append this extension after the closing brace of `AnglesiteShortcuts` (end of file):

```swift
extension AnglesiteShortcuts {
    /// Intent type names that have a curated Siri phrase in `appShortcuts` above. Kept beside the
    /// phrase definitions so adding/removing a phrase naturally updates this — it is the anchor for
    /// operation-descriptor coverage (`OperationDescriptorTests`). Apple's `appShortcuts` is a
    /// type-erased `[AppShortcut]` with no public way to read back the intent type, so this hand
    /// list is required; a sync-guard test asserts its size matches `appShortcuts.count`.
    static let phraseExposedIntentNames: Set<String> = [
        "DeploySiteIntent",
        "BackupSiteIntent",
        "AuditSiteIntent",
        "SearchContentIntent",
        "SiteStatusIntent",
        "AddPageIntent",
        "AddPostIntent",
        "PreviewSiteIntent",
        "EditContentIntent",
    ]
}
```

- [ ] **Step 3: Write the failing data tests**

Create `Tests/AnglesiteIntentsTests/OperationDescriptorTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteIntents

/// Data-level contract tests for the operation-descriptor registry (#235). These assert structure
/// and declared values only; behavioral agreement (routing, content mutation) lives in
/// `OperationDescriptorBehavioralTests`. See the spec for why confirmation and the three site-op
/// side-effects are value-asserted rather than behaviorally cross-checked.
extension AppIntentsTests {
    @Suite("OperationDescriptors")
    struct OperationDescriptorTests {
        @Test("every Siri-phrase intent has a descriptor (coverage anchor)")
        func coverage() {
            let described = Set(AnglesiteOperations.all.map(\.intentTypeName))
            #expect(AnglesiteShortcuts.phraseExposedIntentNames.isSubset(of: described))
        }

        @Test("phrase-exposed name list matches the shortcuts provider count (sync guard)")
        func anchorSync() {
            #expect(AnglesiteShortcuts.appShortcuts.count == AnglesiteShortcuts.phraseExposedIntentNames.count)
        }

        @Test("operationID and intentTypeName are each unique")
        func uniqueness() {
            let ids = AnglesiteOperations.all.map(\.operationID)
            #expect(Set(ids).count == ids.count)
            let names = AnglesiteOperations.all.map(\.intentTypeName)
            #expect(Set(names).count == names.count)
        }

        @Test("descriptor(forIntentTypeName:) resolves a known intent and returns nil otherwise")
        func lookup() {
            #expect(AnglesiteOperations.descriptor(forIntentTypeName: "DeploySiteIntent")?.operationID == "deploy-site")
            #expect(AnglesiteOperations.descriptor(forIntentTypeName: "NotAnIntent") == nil)
        }

        @Test("declared fields match the authoritative value table")
        func declaredFields() throws {
            struct Expected {
                let sideEffect: OperationSideEffect
                let requiresConfirmation: Bool
                let isCancellable: Bool
                let resultShape: OperationResult
            }
            let expected: [String: Expected] = [
                "deploy-site": .init(sideEffect: .publishes, requiresConfirmation: true, isCancellable: true, resultShape: .entity("SiteEntity")),
                "backup-site": .init(sideEffect: .modifiesContent, requiresConfirmation: false, isCancellable: true, resultShape: .entity("SiteEntity")),
                "audit-site": .init(sideEffect: .readOnly, requiresConfirmation: false, isCancellable: true, resultShape: .entity("SiteEntity")),
                "open-site": .init(sideEffect: .readOnly, requiresConfirmation: false, isCancellable: false, resultShape: .none),
                "search-content": .init(sideEffect: .readOnly, requiresConfirmation: false, isCancellable: false, resultShape: .entities("ContentMatchEntity")),
                "site-status": .init(sideEffect: .readOnly, requiresConfirmation: false, isCancellable: false, resultShape: .none),
                "preview-site": .init(sideEffect: .readOnly, requiresConfirmation: false, isCancellable: false, resultShape: .none),
                "add-page": .init(sideEffect: .createsContent, requiresConfirmation: false, isCancellable: true, resultShape: .entity("PageEntity")),
                "add-post": .init(sideEffect: .createsContent, requiresConfirmation: false, isCancellable: true, resultShape: .entity("PostEntity")),
                "edit-content": .init(sideEffect: .modifiesContent, requiresConfirmation: false, isCancellable: true, resultShape: .none),
            ]
            #expect(expected.count == AnglesiteOperations.all.count)
            for descriptor in AnglesiteOperations.all {
                let want = try #require(expected[descriptor.operationID], "no expectation for \(descriptor.operationID)")
                #expect(descriptor.sideEffect == want.sideEffect, "\(descriptor.operationID) sideEffect")
                #expect(descriptor.requiresConfirmation == want.requiresConfirmation, "\(descriptor.operationID) requiresConfirmation")
                #expect(descriptor.isCancellable == want.isCancellable, "\(descriptor.operationID) isCancellable")
                #expect(descriptor.resultShape == want.resultShape, "\(descriptor.operationID) resultShape")
            }
        }

        @Test("mcpToolName is nil for all current entries (forward-looking field)")
        func mcpToolNamesUnset() {
            #expect(AnglesiteOperations.all.allSatisfy { $0.mcpToolName == nil })
        }
    }
}
```

- [ ] **Step 4: Run the data tests**

Run: `swift test --package-path . --filter OperationDescriptors`
Expected: PASS — 6 tests in the `OperationDescriptors` suite.
(If the registry or the shortcut list is mis-edited, `coverage`/`anchorSync`/`declaredFields` fail with a pinpointing message.)

- [ ] **Step 5: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/operation-descriptors
git add Sources/AnglesiteIntents/OperationDescriptor.swift Sources/AnglesiteIntents/AnglesiteShortcuts.swift Tests/AnglesiteIntentsTests/OperationDescriptorTests.swift
git commit -m "$(cat <<'EOF'
feat(intents): operation descriptor model + registry (#235)

Lean OperationDescriptor model describing each Siri-facing operation's
side-effect level, confirmation, cancellability, and result shape, with a
canonical AnglesiteOperations registry. Coverage anchored to
AnglesiteShortcuts via phraseExposedIntentNames and enforced by data tests
(coverage, sync guard, uniqueness, declared-field value table).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Behavioral agreement tests

**Files:**
- Test: `Tests/AnglesiteIntentsTests/OperationDescriptorBehavioralTests.swift`

**Interfaces:**
- Consumes: `AnglesiteOperations` (Task 1); existing seams `SiteOperationsOverride.$scoped` + `FakeOperations` (Tests/AnglesiteIntentsTests/Support/), `ContentOperationsOverride.$scoped`, `ContentGraphOverride.$scoped`, `IntentEditBridgeOverride.$scoped`, `IntentEditBridge(routerProvider:makeID:)`, `EditRouter`/`EditReply`/`EditMessage`, `SiteContentGraph`, `TestStore.site(id:name:)`, `AppIntentsTests.aSite` / `.gPage(route:title:)`, `ElementEntity.makeID(siteID:elementID:)` / `.encodeSelector(_:)`, `JSONValue`.

- [ ] **Step 1: Write the failing behavioral tests**

Create `Tests/AnglesiteIntentsTests/OperationDescriptorBehavioralTests.swift`:

```swift
import Testing
import Foundation
import AppIntents
@testable import AnglesiteCore
@testable import AnglesiteIntents

/// Behavioral agreement for the operation-descriptor registry (#235). Proves each write/edit
/// descriptor maps to a real invoked service call (not a phantom) and that read intents perform no
/// content mutation. Confirmation and the three site-op read/write splits are NOT observable under
/// `swift test` (the seam bypasses `requestConfirmation`; deploy/backup/audit all invoke a command
/// method) — those stay value-asserted in `OperationDescriptorTests`. See the spec for why.
extension AppIntentsTests {
    @Suite("OperationDescriptors.Behavioral", .serialized)
    struct OperationDescriptorBehavioralTests {
        /// Records create calls so a content intent's routing/mutation can be asserted.
        final class RoutingContentOps: ContentOperationsService, @unchecked Sendable {
            private(set) var pageCalls = 0
            private(set) var postCalls = 0
            func createPage(siteID: String, name: String, route: String?) async -> ContentCreateResult {
                pageCalls += 1
                return .created(filePath: "src/pages/x.astro", identifier: "/x")
            }
            func createPost(siteID: String, title: String, collection: String?, slug: String?) async -> ContentCreateResult {
                postCalls += 1
                return .created(filePath: "src/content/posts/x.md", identifier: "x")
            }
        }

        /// Records edit-bridge calls.
        actor RoutingRouter: EditRouter {
            private(set) var received = 0
            func apply(_ message: EditMessage) async -> EditReply {
                received += 1
                return EditReply(id: "x", status: .applied, message: nil)
            }
        }

        private static func site() -> SiteEntity {
            SiteEntity(TestStore.site(id: AppIntentsTests.aSite, name: "Alpha"))
        }

        // MARK: Routing agreement — site ops

        @Test("deploy-site routes to the deploy command only")
        func deployRoutes() async throws {
            let fake = FakeOperations()
            let s = TestStore.site(id: AppIntentsTests.aSite, name: "Alpha")
            fake.sites = [s.id: s]
            fake.deployResult = .succeeded(url: URL(string: "https://x.dev")!, duration: 1)
            try await SiteOperationsOverride.$scoped.withValue(fake) {
                var intent = DeploySiteIntent()
                intent.site = SiteEntity(s)
                _ = try await intent.perform()
            }
            #expect(fake.deployCalls.count == 1)
            #expect(fake.backupCalls.isEmpty)
            #expect(fake.auditCalls.isEmpty)
        }

        @Test("backup-site routes to the backup command only")
        func backupRoutes() async throws {
            let fake = FakeOperations()
            let s = TestStore.site(id: AppIntentsTests.aSite, name: "Alpha")
            fake.sites = [s.id: s]
            try await SiteOperationsOverride.$scoped.withValue(fake) {
                var intent = BackupSiteIntent()
                intent.site = SiteEntity(s)
                _ = try await intent.perform()
            }
            #expect(fake.backupCalls.count == 1)
            #expect(fake.deployCalls.isEmpty)
            #expect(fake.auditCalls.isEmpty)
        }

        @Test("audit-site routes to the audit command only")
        func auditRoutes() async throws {
            let fake = FakeOperations()
            let s = TestStore.site(id: AppIntentsTests.aSite, name: "Alpha")
            fake.sites = [s.id: s]
            try await SiteOperationsOverride.$scoped.withValue(fake) {
                var intent = AuditSiteIntent()
                intent.site = SiteEntity(s)
                _ = try await intent.perform()
            }
            #expect(fake.auditCalls.count == 1)
            #expect(fake.deployCalls.isEmpty)
            #expect(fake.backupCalls.isEmpty)
        }

        // MARK: Content-mutation agreement — creates/edit mutate, reads don't

        @Test("add-page routes to createPage (createsContent)")
        func addPageMutates() async throws {
            let fake = RoutingContentOps()
            try await ContentOperationsOverride.$scoped.withValue(fake) {
                var intent = AddPageIntent()
                intent.site = Self.site()
                intent.name = "X"
                _ = try await intent.perform()
            }
            #expect(fake.pageCalls == 1)
            #expect(fake.postCalls == 0)
        }

        @Test("add-post routes to createPost (createsContent)")
        func addPostMutates() async throws {
            let fake = RoutingContentOps()
            try await ContentOperationsOverride.$scoped.withValue(fake) {
                var intent = AddPostIntent()
                intent.site = Self.site()
                intent.title2 = "Hello"
                _ = try await intent.perform()
            }
            #expect(fake.postCalls == 1)
            #expect(fake.pageCalls == 0)
        }

        @Test("edit-content routes to the edit bridge (modifiesContent)")
        func editMutates() async throws {
            let router = RoutingRouter()
            let bridge = IntentEditBridge(routerProvider: { _ in router }, makeID: { "x" })
            let selector: JSONValue = .object([
                "tag": .string("H1"),
                "classes": .array([]),
                "nthChild": .int(1),
            ])
            let element = ElementEntity(
                id: ElementEntity.makeID(siteID: AppIntentsTests.aSite, elementID: "v-1"),
                displayName: "h1",
                siteID: AppIntentsTests.aSite,
                selector: ElementEntity.encodeSelector(selector),
                pagePath: "/about/"
            )
            let intent = EditContentIntent()
            intent.element = element
            intent.instruction = "make it bigger"
            try await IntentEditBridgeOverride.$scoped.withValue(bridge) {
                _ = try await intent.perform()
            }
            #expect(await router.received == 1)
        }

        @Test("read intents (search, status) perform no content mutation")
        func readsDoNotMutate() async throws {
            let createFake = RoutingContentOps()
            let graph = SiteContentGraph()
            await graph.load(
                siteID: AppIntentsTests.aSite,
                pages: [AppIntentsTests.gPage(route: "/about", title: "About")],
                posts: [],
                images: []
            )
            try await ContentOperationsOverride.$scoped.withValue(createFake) {
                try await ContentGraphOverride.$scoped.withValue(graph) {
                    var search = SearchContentIntent()
                    search.site = Self.site()
                    search.query = "about"
                    _ = try await search.perform()

                    var status = SiteStatusIntent()
                    status.site = Self.site()
                    _ = try await status.perform()
                }
            }
            #expect(createFake.pageCalls == 0)
            #expect(createFake.postCalls == 0)
        }
    }
}
```

- [ ] **Step 2: Run the behavioral tests**

Run: `swift test --package-path . --filter "OperationDescriptors.Behavioral"`
Expected: PASS — 7 tests. If a descriptor claims a side-effect the intent doesn't actually drive (e.g. `add-page` mis-marked `.readOnly` while `createPage` still fires), the mismatch surfaces against the value table in Task 1.

- [ ] **Step 3: Run the full intents suite (no regressions)**

Run: `swift test --package-path . --filter AnglesiteIntentsTests`
Expected: PASS — the pre-existing 145 `@Test`s plus the 13 new ones (6 data + 7 behavioral). Confirms the new `.serialized` suites don't perturb the shared override seams.

- [ ] **Step 4: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/operation-descriptors
git add Tests/AnglesiteIntentsTests/OperationDescriptorBehavioralTests.swift
git commit -m "$(cat <<'EOF'
test(intents): behavioral agreement for operation descriptors (#235)

Routing-agreement tests prove each site/content/edit descriptor maps to a
real invoked service call, and a content-mutation test proves read intents
perform no mutation — the honest behavioral floor the test seams allow.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- Descriptor model (id, name, inputs, side-effect, confirmation, cancellability, result, related intent/MCP names) → Task 1 model. Inputs are intentionally *not* re-declared (auto-derived; spec Non-goals); related MCP name is `mcpToolName` (nil for now); related intent is `intentTypeName`. ✓
- Descriptors cover current operations → Task 1 registry (10 ops) + `coverage` test. ✓
- Deploy/edit require confirmation; read-only marked non-destructive → `declaredFields` value table + `readsDoNotMutate`. ✓ (edit confirmation is currently `false`, flips with #239 — documented.)
- Tests catch missing descriptors → `coverage` + `anchorSync`. ✓
- Tests catch descriptor disagreeing with implementation → behavioral routing + content-mutation (the feasible subset; confirmation/site-op read-write limits documented). ✓
- "Use descriptors in Shortcuts/MCP/diagnostics" → out of scope this issue (spec Non-goals; #236 consumes next). ✓

**Placeholder scan:** none — all steps contain complete code and exact commands.

**Type consistency:** `OperationDescriptor`/`OperationSideEffect`/`OperationResult`/`AnglesiteOperations.all`/`descriptor(forIntentTypeName:)`/`phraseExposedIntentNames` are used identically in Tasks 1 and 2. Intent parameter names verified against source: `AddPostIntent.title2`, `SearchContentIntent.query`, `AddPageIntent.name`. Fake/​seam names verified: `FakeOperations.deployCalls/backupCalls/auditCalls`, `ContentOperationsService.createPage/createPost`, `EditRouter.apply(_:)`, `EditReply(id:status:message:)`, `DeployCommand.Result.succeeded(url:duration:)`.
