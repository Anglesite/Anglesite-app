# Siri AI Readiness Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only, network-free diagnostic that reports whether Siri-driven workflows can work — globally (Settings "Siri AI" tab) and per-site (a `SiteWindow` command).

**Architecture:** A `ReadinessProbe` protocol (each probe returns a `ReadinessFinding`, never throws) feeds a `@MainActor @Observable SiriReadinessModel`, mirroring the shipped `HealthModel`/`HealthCheckRunner` pattern. Shared types + Foundation-only probes live in `AnglesiteCore`; App-Intents/Spotlight probes live in `AnglesiteIntents`; probe arrays are assembled in `AnglesiteIntents`; only SwiftUI views live in the app target. Every probe's mapping is pure given injected primitives, so all logic is CI-testable without touching system frameworks.

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27), Swift Testing for new tests, `FoundationModels` + `CoreSpotlight` + `AppIntents` system frameworks (read-only, behind injected seams).

**Spec:** `docs/specs/2026-06-18-siri-readiness-design.md`

## Global Constraints

- Target **macOS 27+**, Swift 6.4 / Xcode 27. No `@available` fallbacks; use `#if compiler(>=6.4)` where needed.
- **No third-party frameworks.** Apple frameworks only.
- **New tests use Swift Testing** (`@Test` / `#expect`), per the suite migration (#74).
- **Probe/model logic lives in `AnglesiteCore` or `AnglesiteIntents`** (both CI-covered), never the app target. App target gets SwiftUI views only.
- **No network access** in any probe. The Foundation Models probe checks *availability only* — it never runs inference.
- **MAS:** the Settings tab needs no filesystem access; per-site probes run from a `SiteWindow` that already holds the security-scoped grant. Guard with `#if ANGLESITE_MAS` only where strictly required (none expected in this plan).
- Verify with `swift test --package-path .` AND an `xcodebuild` build of both `Anglesite` and `AnglesiteMAS` schemes (per project: `swift test` alone doesn't prove the `.app` links).
- Commit after every green step.

---

### Task 1: Core readiness primitives + model

**Files:**
- Create: `Sources/AnglesiteCore/SiriReadiness.swift`
- Test: `Tests/AnglesiteCoreTests/SiriReadinessModelTests.swift`

**Interfaces:**
- Produces: `ReadinessLevel`, `ReadinessFinding`, `ReadinessProbe`, `SiriReadinessModel` — consumed by every later task.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/SiriReadinessModelTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

private struct StubProbe: ReadinessProbe {
    let id: String
    let title: String
    let finding: ReadinessFinding
    init(_ finding: ReadinessFinding) {
        self.id = finding.id
        self.title = finding.title
        self.finding = finding
    }
    func check() async -> ReadinessFinding { finding }
}

private func makeFinding(_ id: String, _ level: ReadinessLevel) -> ReadinessFinding {
    ReadinessFinding(id: id, title: id, level: level, detail: "detail")
}

@MainActor
@Suite struct SiriReadinessModelTests {
    @Test func initialState_isEmpty() {
        let model = SiriReadinessModel(probes: [])
        #expect(model.findings.isEmpty)
        #expect(model.isChecking == false)
        #expect(model.lastChecked == nil)
    }

    @Test func recheck_collectsFindingsInOrder_andStampsTime() async {
        let stamp = Date(timeIntervalSince1970: 1000)
        let model = SiriReadinessModel(
            probes: [StubProbe(makeFinding("a", .ok)), StubProbe(makeFinding("b", .warning))],
            now: { stamp }
        )
        await model.recheck().value
        #expect(model.findings.map(\.id) == ["a", "b"])
        #expect(model.isChecking == false)
        #expect(model.lastChecked == stamp)
    }

    @Test func overallLevel_failureWins() async {
        let model = SiriReadinessModel(probes: [
            StubProbe(makeFinding("a", .ok)),
            StubProbe(makeFinding("b", .warning)),
            StubProbe(makeFinding("c", .failure)),
        ])
        await model.recheck().value
        #expect(model.overallLevel == .failure)
    }

    @Test func overallLevel_allUnsupported_isUnsupported() async {
        let model = SiriReadinessModel(probes: [StubProbe(makeFinding("a", .unsupported))])
        await model.recheck().value
        #expect(model.overallLevel == .unsupported)
    }

    @Test func overallLevel_mixOkAndUnsupported_isOk() async {
        let model = SiriReadinessModel(probes: [
            StubProbe(makeFinding("a", .ok)),
            StubProbe(makeFinding("b", .unsupported)),
        ])
        await model.recheck().value
        #expect(model.overallLevel == .ok)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter SiriReadinessModelTests`
Expected: FAIL — `cannot find 'SiriReadinessModel' in scope` (and the other types).

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnglesiteCore/SiriReadiness.swift
import Foundation
import Observation

/// Severity of a single capability check. `unsupported` means "not available in this
/// build/OS yet" (a truthful absence, not a failure the user caused).
public enum ReadinessLevel: String, Sendable, Equatable, CaseIterable {
    case ok
    case warning
    case failure
    case unsupported
}

/// The result of one probe. Concrete `detail` (what the probe found), with optional
/// user-actionable `remediation`.
public struct ReadinessFinding: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let level: ReadinessLevel
    public let detail: String
    public let remediation: String?

    public init(id: String, title: String, level: ReadinessLevel, detail: String, remediation: String? = nil) {
        self.id = id
        self.title = title
        self.level = level
        self.detail = detail
        self.remediation = remediation
    }
}

/// A single capability check. Never throws — a failure is a `ReadinessFinding` with a
/// failing `level`. Injectable so tests can supply canned probes.
public protocol ReadinessProbe: Sendable {
    var id: String { get }
    var title: String { get }
    func check() async -> ReadinessFinding
}

/// Drives a readiness surface. Mirrors `HealthModel`: `@MainActor @Observable`, injectable
/// dependencies, `recheck()` returns the `Task` so tests can await it. Probes run serially
/// for deterministic ordering.
@MainActor
@Observable
public final class SiriReadinessModel {
    public private(set) var findings: [ReadinessFinding] = []
    public private(set) var isChecking: Bool = false
    public private(set) var lastChecked: Date?

    @ObservationIgnored private let probes: [any ReadinessProbe]
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    public init(probes: [any ReadinessProbe], now: @escaping @Sendable () -> Date = { Date() }) {
        self.probes = probes
        self.now = now
    }

    /// Worst level across all findings. Empty / all-unsupported collapses to `.unsupported`.
    public var overallLevel: ReadinessLevel {
        if findings.contains(where: { $0.level == .failure }) { return .failure }
        if findings.contains(where: { $0.level == .warning }) { return .warning }
        if findings.contains(where: { $0.level == .ok }) { return .ok }
        return .unsupported
    }

    /// Run every probe and publish the findings. Cancels any in-flight run first.
    @discardableResult
    public func recheck() -> Task<Void, Never> {
        inFlight?.cancel()
        isChecking = true
        let probes = self.probes
        let task = Task { @MainActor [weak self] in
            var collected: [ReadinessFinding] = []
            for probe in probes {
                if Task.isCancelled { return }
                collected.append(await probe.check())
            }
            guard !Task.isCancelled else { return }
            self?.commit(collected)
        }
        inFlight = task
        return task
    }

    private func commit(_ findings: [ReadinessFinding]) {
        self.findings = findings
        self.lastChecked = now()
        self.isChecking = false
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter SiriReadinessModelTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiriReadiness.swift Tests/AnglesiteCoreTests/SiriReadinessModelTests.swift
git commit -m "feat(siri): readiness probe protocol + observable model (#236)"
```

---

### Task 2: Core system probes — OS runtime + Foundation Models

**Files:**
- Create: `Sources/AnglesiteCore/SiriReadinessSystemProbes.swift`
- Test: `Tests/AnglesiteCoreTests/SiriReadinessSystemProbeTests.swift`

**Interfaces:**
- Consumes: `ReadinessProbe`, `ReadinessFinding`, `ReadinessLevel` (Task 1).
- Produces: `OSRuntimeProbe`, `FoundationModelsAvailability`, `FoundationModelsProbe`, `LiveFoundationModelsAvailability.current()` — consumed by Task 5.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/SiriReadinessSystemProbeTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct SiriReadinessSystemProbeTests {
    @Test func osRuntime_meetsMinimum_isOk() async {
        let probe = OSRuntimeProbe(
            version: OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 0),
            minimumMajor: 27
        )
        let finding = await probe.check()
        #expect(finding.id == "os.runtime")
        #expect(finding.level == .ok)
    }

    @Test func osRuntime_belowMinimum_isFailure_withRemediation() async {
        let probe = OSRuntimeProbe(
            version: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            minimumMajor: 27
        )
        let finding = await probe.check()
        #expect(finding.level == .failure)
        #expect(finding.remediation != nil)
    }

    @Test func foundationModels_available_isOk() async {
        let probe = FoundationModelsProbe(availability: { .available })
        let finding = await probe.check()
        #expect(finding.id == "foundation.models")
        #expect(finding.level == .ok)
    }

    @Test func foundationModels_appleIntelligenceOff_isWarning_withRemediation() async {
        let probe = FoundationModelsProbe(availability: { .appleIntelligenceNotEnabled })
        let finding = await probe.check()
        #expect(finding.level == .warning)
        #expect(finding.remediation != nil)
    }

    @Test func foundationModels_deviceNotEligible_isUnsupported() async {
        let probe = FoundationModelsProbe(availability: { .deviceNotEligible })
        let finding = await probe.check()
        #expect(finding.level == .unsupported)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter SiriReadinessSystemProbeTests`
Expected: FAIL — `cannot find 'OSRuntimeProbe' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnglesiteCore/SiriReadinessSystemProbes.swift
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Confirms the running OS meets Anglesite's macOS floor. Version is injectable so the
/// mapping is testable without spoofing the process environment.
public struct OSRuntimeProbe: ReadinessProbe {
    public let id = "os.runtime"
    public let title = "macOS runtime"
    private let version: OperatingSystemVersion
    private let minimumMajor: Int

    public init(
        version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        minimumMajor: Int = 27
    ) {
        self.version = version
        self.minimumMajor = minimumMajor
    }

    public func check() async -> ReadinessFinding {
        let running = "\(version.majorVersion).\(version.minorVersion)"
        if version.majorVersion >= minimumMajor {
            return ReadinessFinding(id: id, title: title, level: .ok,
                detail: "macOS \(running) meets the macOS \(minimumMajor) requirement for Siri workflows.")
        }
        return ReadinessFinding(id: id, title: title, level: .failure,
            detail: "macOS \(running) is below the macOS \(minimumMajor) requirement.",
            remediation: "Update to macOS \(minimumMajor) or later in System Settings ▸ General ▸ Software Update.")
    }
}

/// Normalized Foundation Models availability, decoupled from the SDK enum so the probe
/// mapping is testable without the framework.
public enum FoundationModelsAvailability: Sendable, Equatable {
    case available
    case appleIntelligenceNotEnabled
    case modelNotReady
    case deviceNotEligible
    case unknown(String)
}

/// Reports whether Apple's on-device language model is usable. Availability is injected so
/// tests never touch the live model; the live source reads `SystemLanguageModel` (no inference).
public struct FoundationModelsProbe: ReadinessProbe {
    public let id = "foundation.models"
    public let title = "Apple Foundation Models"
    private let availability: @Sendable () -> FoundationModelsAvailability

    public init(availability: @escaping @Sendable () -> FoundationModelsAvailability) {
        self.availability = availability
    }

    public func check() async -> ReadinessFinding {
        switch availability() {
        case .available:
            return ReadinessFinding(id: id, title: title, level: .ok,
                detail: "The on-device language model is available for summarization and chat.")
        case .appleIntelligenceNotEnabled:
            return ReadinessFinding(id: id, title: title, level: .warning,
                detail: "Apple Intelligence is turned off.",
                remediation: "Enable Apple Intelligence in System Settings ▸ Apple Intelligence & Siri.")
        case .modelNotReady:
            return ReadinessFinding(id: id, title: title, level: .warning,
                detail: "The on-device model is still downloading or preparing.",
                remediation: "Wait for the model to finish downloading, then re-check.")
        case .deviceNotEligible:
            return ReadinessFinding(id: id, title: title, level: .unsupported,
                detail: "This Mac does not support Apple Foundation Models.")
        case .unknown(let reason):
            return ReadinessFinding(id: id, title: title, level: .warning,
                detail: "Foundation Models availability could not be determined: \(reason).")
        }
    }
}

/// Live availability source. Reads `SystemLanguageModel.default.availability` (no inference).
/// Case names below must match the `FoundationModels` SDK; `@unknown default` absorbs drift.
public enum LiveFoundationModelsAvailability {
    public static func current() -> FoundationModelsAvailability {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
            case .modelNotReady: return .modelNotReady
            case .deviceNotEligible: return .deviceNotEligible
            @unknown default: return .unknown("\(reason)")
            }
        @unknown default:
            return .unknown("unrecognized availability")
        }
        #else
        return .unknown("FoundationModels unavailable at build time")
        #endif
    }
}
```

> **Implementer note:** if the SDK enum case labels differ (e.g. `.unavailable(.appleIntelligenceNotEnabled)` spelled differently), adjust the mapping in `LiveFoundationModelsAvailability.current()` only — the probe and its tests are insulated from the SDK names.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter SiriReadinessSystemProbeTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiriReadinessSystemProbes.swift Tests/AnglesiteCoreTests/SiriReadinessSystemProbeTests.swift
git commit -m "feat(siri): OS-runtime + Foundation Models readiness probes (#236)"
```

---

### Task 3: Intents-module system probes — App Intents, View Annotations, MCP bridge

**Files:**
- Create: `Sources/AnglesiteIntents/SiriReadinessIntentProbes.swift`
- Test: `Tests/AnglesiteIntentsTests/SiriReadinessIntentProbeTests.swift`

**Interfaces:**
- Consumes: `ReadinessProbe`/`ReadinessFinding` (from `AnglesiteCore`), `AnglesiteShortcuts.appShortcuts`.
- Produces: `AppIntentsRegistrationProbe`, `ViewAnnotationsProbe` (+ static `builtWithAnnotations`), `SystemMCPBridgeProbe` — consumed by Task 5.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteIntentsTests/SiriReadinessIntentProbeTests.swift
import Testing
import AnglesiteCore
@testable import AnglesiteIntents

@Suite struct SiriReadinessIntentProbeTests {
    @Test func appIntents_withShortcuts_isOk() async {
        let finding = await AppIntentsRegistrationProbe(shortcutCount: 9).check()
        #expect(finding.id == "intents.registration")
        #expect(finding.level == .ok)
    }

    @Test func appIntents_noShortcuts_isWarning() async {
        let finding = await AppIntentsRegistrationProbe(shortcutCount: 0).check()
        #expect(finding.level == .warning)
        #expect(finding.remediation != nil)
    }

    @Test func appIntents_defaultUsesRealShortcuts() async {
        // The real provider ships curated shortcuts, so the default init must report ok.
        let finding = await AppIntentsRegistrationProbe().check()
        #expect(finding.level == .ok)
    }

    @Test func viewAnnotations_compiled_isOk() async {
        let finding = await ViewAnnotationsProbe(compiled: true).check()
        #expect(finding.id == "view.annotations")
        #expect(finding.level == .ok)
    }

    @Test func viewAnnotations_notCompiled_isUnsupported() async {
        let finding = await ViewAnnotationsProbe(compiled: false).check()
        #expect(finding.level == .unsupported)
    }

    @Test func mcpBridge_unregistered_isUnsupported() async {
        let finding = await SystemMCPBridgeProbe(registered: false).check()
        #expect(finding.id == "mcp.bridge")
        #expect(finding.level == .unsupported)
    }

    @Test func mcpBridge_registered_isOk() async {
        let finding = await SystemMCPBridgeProbe(registered: true).check()
        #expect(finding.level == .ok)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter SiriReadinessIntentProbeTests`
Expected: FAIL — `cannot find 'AppIntentsRegistrationProbe' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnglesiteIntents/SiriReadinessIntentProbes.swift
import AnglesiteCore
import AppIntents

/// Confirms Anglesite's App Shortcuts are registered (the surface Siri/Spotlight enumerate).
/// Count is injectable; the default reads the live provider.
public struct AppIntentsRegistrationProbe: ReadinessProbe {
    public let id = "intents.registration"
    public let title = "App Intents & Shortcuts"
    private let shortcutCount: Int

    public init(shortcutCount: Int = AnglesiteShortcuts.appShortcuts.count) {
        self.shortcutCount = shortcutCount
    }

    public func check() async -> ReadinessFinding {
        if shortcutCount > 0 {
            return ReadinessFinding(id: id, title: title, level: .ok,
                detail: "\(shortcutCount) Anglesite shortcuts are registered for Siri and Spotlight.")
        }
        return ReadinessFinding(id: id, title: title, level: .warning,
            detail: "No Anglesite shortcuts are registered.",
            remediation: "Relaunch Anglesite so the system re-registers its App Shortcuts.")
    }
}

/// Reports whether the build includes Swift 6.4 View Annotations (the onscreen-awareness path
/// that lets Siri act on the site you're viewing). Compile-time gated; injectable for tests.
public struct ViewAnnotationsProbe: ReadinessProbe {
    public let id = "view.annotations"
    public let title = "Onscreen awareness (View Annotations)"
    private let compiled: Bool

    public init(compiled: Bool = ViewAnnotationsProbe.builtWithAnnotations) {
        self.compiled = compiled
    }

    public static var builtWithAnnotations: Bool {
        #if compiler(>=6.4)
        return true
        #else
        return false
        #endif
    }

    public func check() async -> ReadinessFinding {
        if compiled {
            return ReadinessFinding(id: id, title: title, level: .ok,
                detail: "Site windows publish an entity identifier, so Siri can act on the site you're viewing.")
        }
        return ReadinessFinding(id: id, title: title, level: .unsupported,
            detail: "This build was compiled without Swift 6.4 view-annotation support.",
            remediation: "Use a build produced with Xcode 27 / Swift 6.4 or later.")
    }
}

/// Reports whether Anglesite's tools are exposed to the system-wide MCP bridge. Unbuilt today
/// (Phase D, #135) — defaults to `.unsupported`; flips to a real check when #164/#101 land.
public struct SystemMCPBridgeProbe: ReadinessProbe {
    public let id = "mcp.bridge"
    public let title = "System-wide MCP bridge"
    private let registered: Bool

    public init(registered: Bool = false) {
        self.registered = registered
    }

    public func check() async -> ReadinessFinding {
        if registered {
            return ReadinessFinding(id: id, title: title, level: .ok,
                detail: "Anglesite's tools are exposed to the system MCP bridge for Claude Code and other agents.")
        }
        return ReadinessFinding(id: id, title: title, level: .unsupported,
            detail: "System-wide MCP exposure is not available in this build (Phase D, #135).")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter SiriReadinessIntentProbeTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIntents/SiriReadinessIntentProbes.swift Tests/AnglesiteIntentsTests/SiriReadinessIntentProbeTests.swift
git commit -m "feat(siri): App Intents / View Annotations / MCP-bridge readiness probes (#236)"
```

---

### Task 4: Site probes — content-graph freshness + Spotlight index status

**Files:**
- Modify: `Sources/AnglesiteIntents/ContentSpotlightIndexer.swift` (add `IndexedCounts` + `indexedCounts(for:)`)
- Modify: `Sources/AnglesiteIntents/Bootstrap.swift` (return the `ContentSpotlightIndexer` so the app can hold it)
- Create: `Sources/AnglesiteCore/SiriReadinessSiteProbes.swift` (content-graph probe)
- Create: `Sources/AnglesiteIntents/SiriReadinessSpotlightProbe.swift` (Spotlight probe)
- Test: `Tests/AnglesiteCoreTests/SiriReadinessSiteProbeTests.swift`, `Tests/AnglesiteIntentsTests/SiriReadinessSpotlightProbeTests.swift`

**Interfaces:**
- Consumes: `ReadinessProbe`/`ReadinessFinding` (Task 1), `SiteContentGraph` (Core), `ContentSpotlightIndexer` (Intents).
- Produces: `ContentSpotlightIndexer.IndexedCounts`, `ContentSpotlightIndexer.indexedCounts(for:) -> IndexedCounts`, `AnglesiteIntents.bootstrap(contentGraph:) async -> ContentSpotlightIndexer`, `ContentGraphProbe`, `SpotlightIndexProbe` — consumed by Tasks 5 & 7.

- [ ] **Step 1: Write the failing test (content-graph probe, Core)**

```swift
// Tests/AnglesiteCoreTests/SiriReadinessSiteProbeTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct SiriReadinessSiteProbeTests {
    private func page(_ site: String, _ route: String) -> SiteContentGraph.Page {
        SiteContentGraph.Page(id: "\(site):page:\(route)", siteID: site, route: route,
                              filePath: "/\(route).md", title: route, lastModified: Date(timeIntervalSince1970: 0))
    }

    @Test func contentGraph_populated_isOk() async {
        let graph = SiteContentGraph()
        await graph.load(siteID: "blog", pages: [page("blog", "about")], posts: [], images: [])
        let finding = await ContentGraphProbe(siteID: "blog", graph: graph).check()
        #expect(finding.id == "site.graph")
        #expect(finding.level == .ok)
    }

    @Test func contentGraph_empty_isWarning_withRemediation() async {
        let graph = SiteContentGraph()
        let finding = await ContentGraphProbe(siteID: "blog", graph: graph).check()
        #expect(finding.level == .warning)
        #expect(finding.remediation != nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter SiriReadinessSiteProbeTests`
Expected: FAIL — `cannot find 'ContentGraphProbe' in scope`.

- [ ] **Step 3: Implement the content-graph probe**

```swift
// Sources/AnglesiteCore/SiriReadinessSiteProbes.swift
import Foundation

/// Reports whether a site's content is loaded into the in-memory graph (the data Siri's
/// search/status intents read). Empty is a warning, not a failure — the user just needs to
/// open the site.
public struct ContentGraphProbe: ReadinessProbe {
    public let id = "site.graph"
    public let title = "Site content index"
    private let siteID: String
    private let graph: SiteContentGraph

    public init(siteID: String, graph: SiteContentGraph) {
        self.siteID = siteID
        self.graph = graph
    }

    public func check() async -> ReadinessFinding {
        let pages = await graph.pages(for: siteID).count
        let posts = await graph.posts(for: siteID).count
        let images = await graph.images(for: siteID).count
        if pages + posts + images > 0 {
            return ReadinessFinding(id: id, title: title, level: .ok,
                detail: "\(pages) pages, \(posts) posts, \(images) images are loaded for Siri to search.")
        }
        return ReadinessFinding(id: id, title: title, level: .warning,
            detail: "No content is loaded for this site yet.",
            remediation: "Open this site's window so Anglesite can index its content.")
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path . --filter SiriReadinessSiteProbeTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Write the failing test (indexer accessor + Spotlight probe, Intents)**

```swift
// Tests/AnglesiteIntentsTests/SiriReadinessSpotlightProbeTests.swift
import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteIntents

private actor NoopSpotlightBackend: ContentSpotlightBackend {
    func indexPages(_ entities: [PageEntity]) async throws {}
    func indexPosts(_ entities: [PostEntity]) async throws {}
    func indexImages(_ entities: [ImageEntity]) async throws {}
    func deletePages(identifiers: [String]) async throws {}
    func deletePosts(identifiers: [String]) async throws {}
    func deleteImages(identifiers: [String]) async throws {}
}

@Suite struct SiriReadinessSpotlightProbeTests {
    private func page(_ site: String, _ route: String) -> SiteContentGraph.Page {
        SiteContentGraph.Page(id: "\(site):page:\(route)", siteID: site, route: route,
                              filePath: "/\(route).md", title: route, lastModified: Date(timeIntervalSince1970: 0))
    }

    @Test func indexedCounts_reflectReindex() async throws {
        let graph = SiteContentGraph()
        let indexer = ContentSpotlightIndexer(graph: graph, backend: NoopSpotlightBackend())
        await graph.load(siteID: "blog", pages: [page("blog", "about")], posts: [], images: [])
        _ = try await indexer.reindex(siteID: "blog")
        let counts = await indexer.indexedCounts(for: "blog")
        #expect(counts.pages == 1)
        #expect(counts.total == 1)
    }

    @Test func spotlight_indexed_isOk() async throws {
        let graph = SiteContentGraph()
        let indexer = ContentSpotlightIndexer(graph: graph, backend: NoopSpotlightBackend())
        await graph.load(siteID: "blog", pages: [page("blog", "about")], posts: [], images: [])
        _ = try await indexer.reindex(siteID: "blog")
        let finding = await SpotlightIndexProbe(siteID: "blog", indexer: indexer, indexingAvailable: true).check()
        #expect(finding.id == "site.spotlight")
        #expect(finding.level == .ok)
    }

    @Test func spotlight_nothingIndexed_isWarning() async {
        let graph = SiteContentGraph()
        let indexer = ContentSpotlightIndexer(graph: graph, backend: NoopSpotlightBackend())
        let finding = await SpotlightIndexProbe(siteID: "blog", indexer: indexer, indexingAvailable: true).check()
        #expect(finding.level == .warning)
    }

    @Test func spotlight_unavailable_isWarning_withRemediation() async {
        let graph = SiteContentGraph()
        let indexer = ContentSpotlightIndexer(graph: graph, backend: NoopSpotlightBackend())
        let finding = await SpotlightIndexProbe(siteID: "blog", indexer: indexer, indexingAvailable: false).check()
        #expect(finding.level == .warning)
        #expect(finding.remediation != nil)
    }
}
```

- [ ] **Step 6: Run to verify it fails**

Run: `swift test --package-path . --filter SiriReadinessSpotlightProbeTests`
Expected: FAIL — `value of type 'ContentSpotlightIndexer' has no member 'indexedCounts'`.

- [ ] **Step 7: Add the indexer accessor**

In `Sources/AnglesiteIntents/ContentSpotlightIndexer.swift`, add inside the `ContentSpotlightIndexer` actor (e.g. just after the `Outcome` struct):

```swift
    /// Snapshot of how many entities are currently published to Spotlight for a site. Reads the
    /// `lastIndexed` set this indexer maintains — the truthful "what we've put in the index" count
    /// without querying the system daemon. Returns zeros for an unknown / never-indexed site.
    public struct IndexedCounts: Sendable, Equatable {
        public let pages: Int
        public let posts: Int
        public let images: Int
        public var total: Int { pages + posts + images }
        public init(pages: Int, posts: Int, images: Int) {
            self.pages = pages
            self.posts = posts
            self.images = images
        }
    }

    public func indexedCounts(for siteID: String) -> IndexedCounts {
        guard let state = lastIndexed[siteID] else { return IndexedCounts(pages: 0, posts: 0, images: 0) }
        return IndexedCounts(pages: state.pageIDs.count, posts: state.postIDs.count, images: state.imageIDs.count)
    }
```

- [ ] **Step 8: Implement the Spotlight probe**

```swift
// Sources/AnglesiteIntents/SiriReadinessSpotlightProbe.swift
import AnglesiteCore
import CoreSpotlight

/// Reports how many of a site's items are published to the Spotlight semantic index Siri reads.
/// `indexingAvailable` is injected; the default reads `CSSearchableIndex.isIndexingAvailable()`.
public struct SpotlightIndexProbe: ReadinessProbe {
    public let id = "site.spotlight"
    public let title = "Spotlight index"
    private let siteID: String
    private let indexer: ContentSpotlightIndexer
    private let indexingAvailable: Bool

    public init(
        siteID: String,
        indexer: ContentSpotlightIndexer,
        indexingAvailable: Bool = CSSearchableIndex.isIndexingAvailable()
    ) {
        self.siteID = siteID
        self.indexer = indexer
        self.indexingAvailable = indexingAvailable
    }

    public func check() async -> ReadinessFinding {
        guard indexingAvailable else {
            return ReadinessFinding(id: id, title: title, level: .warning,
                detail: "Spotlight indexing is unavailable on this Mac.",
                remediation: "Make sure Spotlight is enabled in System Settings ▸ Siri & Spotlight.")
        }
        let counts = await indexer.indexedCounts(for: siteID)
        if counts.total > 0 {
            return ReadinessFinding(id: id, title: title, level: .ok,
                detail: "\(counts.total) items are indexed in Spotlight for this site.")
        }
        return ReadinessFinding(id: id, title: title, level: .warning,
            detail: "Nothing is indexed in Spotlight for this site yet.",
            remediation: "Open this site's window so its content is indexed.")
    }
}
```

- [ ] **Step 9: Run to verify pass**

Run: `swift test --package-path . --filter SiriReadinessSpotlightProbeTests`
Expected: PASS (4 tests).

- [ ] **Step 10: Expose the indexer from `bootstrap`**

In `Sources/AnglesiteIntents/Bootstrap.swift`, change the signature and return the indexer so the app can hold it (mirrors how `contentGraph` is app-owned). Change:

```swift
    public static func bootstrap(contentGraph: SiteContentGraph) async {
```
to:
```swift
    @discardableResult
    public static func bootstrap(contentGraph: SiteContentGraph) async -> ContentSpotlightIndexer {
```
and at the end of the method (after the `do { try await SiteStore.shared.load() } …` block), add:
```swift
        return contentIndexer
```

(`contentIndexer` is already the local created at the existing line `let contentIndexer = ContentSpotlightIndexer(...)`.)

- [ ] **Step 11: Run the full Intents + Core suites to confirm nothing regressed**

Run: `swift test --package-path . --filter AnglesiteIntentsTests`
Then: `swift test --package-path . --filter SiriReadiness`
Expected: PASS. (The `@discardableResult` keeps existing `await AnglesiteIntents.bootstrap(...)` call sites valid.)

- [ ] **Step 12: Commit**

```bash
git add Sources/AnglesiteIntents/ContentSpotlightIndexer.swift Sources/AnglesiteIntents/Bootstrap.swift Sources/AnglesiteCore/SiriReadinessSiteProbes.swift Sources/AnglesiteIntents/SiriReadinessSpotlightProbe.swift Tests/AnglesiteCoreTests/SiriReadinessSiteProbeTests.swift Tests/AnglesiteIntentsTests/SiriReadinessSpotlightProbeTests.swift
git commit -m "feat(siri): per-site content-graph + Spotlight readiness probes (#236)"
```

---

### Task 5: Probe assembly

**Files:**
- Create: `Sources/AnglesiteIntents/SiriReadinessProbes.swift`
- Test: `Tests/AnglesiteIntentsTests/SiriReadinessProbesTests.swift`

**Interfaces:**
- Consumes: all probe types (Tasks 2–4), `SiteContentGraph`, `ContentSpotlightIndexer`.
- Produces: `SiriReadinessProbes.system() -> [any ReadinessProbe]`, `SiriReadinessProbes.site(siteID:graph:indexer:) -> [any ReadinessProbe]` — consumed by Tasks 6 & 7.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteIntentsTests/SiriReadinessProbesTests.swift
import Testing
import AnglesiteCore
@testable import AnglesiteIntents

@Suite struct SiriReadinessProbesTests {
    @Test func system_isNonEmpty_withUniqueIDs() {
        let ids = SiriReadinessProbes.system().map(\.id)
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count)
    }

    @Test func site_isNonEmpty_withUniqueIDs() {
        let graph = SiteContentGraph()
        let indexer = ContentSpotlightIndexer(graph: graph, backend: LiveContentSpotlightBackend())
        let ids = SiriReadinessProbes.site(siteID: "blog", graph: graph, indexer: indexer).map(\.id)
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count)
    }

    @Test func system_andSite_idsDoNotCollide() {
        let graph = SiteContentGraph()
        let indexer = ContentSpotlightIndexer(graph: graph, backend: LiveContentSpotlightBackend())
        let system = Set(SiriReadinessProbes.system().map(\.id))
        let site = Set(SiriReadinessProbes.site(siteID: "blog", graph: graph, indexer: indexer).map(\.id))
        #expect(system.isDisjoint(with: site))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter SiriReadinessProbesTests`
Expected: FAIL — `cannot find 'SiriReadinessProbes' in scope`.

- [ ] **Step 3: Implement the assembly**

```swift
// Sources/AnglesiteIntents/SiriReadinessProbes.swift
import AnglesiteCore

/// Assembles the readiness probe sets. Lives in AnglesiteIntents — the one module that can see
/// both the Core probes and the Intents probes.
public enum SiriReadinessProbes {
    /// Global capabilities, independent of any site.
    public static func system() -> [any ReadinessProbe] {
        [
            OSRuntimeProbe(),
            AppIntentsRegistrationProbe(),
            ViewAnnotationsProbe(),
            FoundationModelsProbe(availability: { LiveFoundationModelsAvailability.current() }),
            SystemMCPBridgeProbe(),
        ]
    }

    /// Per-site readiness for one open/known site.
    public static func site(
        siteID: String,
        graph: SiteContentGraph,
        indexer: ContentSpotlightIndexer
    ) -> [any ReadinessProbe] {
        [
            ContentGraphProbe(siteID: siteID, graph: graph),
            SpotlightIndexProbe(siteID: siteID, indexer: indexer),
        ]
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path . --filter SiriReadinessProbesTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIntents/SiriReadinessProbes.swift Tests/AnglesiteIntentsTests/SiriReadinessProbesTests.swift
git commit -m "feat(siri): assemble system + per-site readiness probe sets (#236)"
```

---

### Task 6: Settings "Siri AI" tab

**Files:**
- Create: `Sources/AnglesiteApp/SiriReadinessView.swift` (shared `ReadinessRow` + `SiriReadinessList` + `SiriReadinessSettingsView`)
- Modify: `Sources/AnglesiteApp/SettingsView.swift` (add the tab)

**Interfaces:**
- Consumes: `SiriReadinessModel` (Core), `SiriReadinessProbes.system()` (Intents), `ReadinessFinding`/`ReadinessLevel` (Core).
- Produces: `ReadinessRow`, `SiriReadinessList`, `SiriReadinessSettingsView` — `SiriReadinessList` reused by Task 7.

This task has no unit test (SwiftUI views in the app target aren't CI-hosted — per CLAUDE.md). It is verified by the `xcodebuild` link check in Step 3 and the manual check note.

- [ ] **Step 1: Create the shared views + settings tab content**

```swift
// Sources/AnglesiteApp/SiriReadinessView.swift
import SwiftUI
import AnglesiteCore

/// One capability row: status glyph + title + concrete detail + optional remediation.
struct ReadinessRow: View {
    let finding: ReadinessFinding

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: glyph)
                .foregroundStyle(tint)
                .accessibilityLabel(accessibilityStatus)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title).font(.body)
                Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                if let remediation = finding.remediation {
                    Text(remediation).font(.caption).foregroundStyle(.blue)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var glyph: String {
        switch finding.level {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        case .unsupported: return "minus.circle"
        }
    }

    private var tint: Color {
        switch finding.level {
        case .ok: return .green
        case .warning: return .orange
        case .failure: return .red
        case .unsupported: return .secondary
        }
    }

    private var accessibilityStatus: String {
        switch finding.level {
        case .ok: return "OK"
        case .warning: return "Warning"
        case .failure: return "Failure"
        case .unsupported: return "Not available"
        }
    }
}

/// Renders a readiness model: the findings list, a re-check button, and a last-checked stamp.
/// Drives an initial check on appear. Reused by Settings (system) and the per-window sheet.
struct SiriReadinessList: View {
    @State var model: SiriReadinessModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.findings) { finding in
                ReadinessRow(finding: finding)
            }
            HStack {
                Button("Re-check") { model.recheck() }
                    .disabled(model.isChecking)
                if model.isChecking {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if let checked = model.lastChecked {
                    Text("Last checked \(checked.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task { if model.findings.isEmpty { model.recheck() } }
    }
}

/// Settings ▸ Siri AI. System-wide capabilities only; per-site readiness lives in each site window.
struct SiriReadinessSettingsView: View {
    @State private var model = SiriReadinessModel(probes: SiriReadinessProbes.system())

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Whether this Mac can run Siri-driven Anglesite workflows. Per-site readiness is in each site window (Site ▸ Siri AI Readiness).")
                    .font(.caption).foregroundStyle(.secondary)
                SiriReadinessList(model: model)
            }
            .padding()
        }
    }
}
```

> **Import note:** `SiriReadinessProbes` is in `AnglesiteIntents`. If the app target file does not already transitively import it, add `import AnglesiteIntents` at the top of this file. (The app target links `AnglesiteIntents` for App Shortcuts.)

- [ ] **Step 2: Add the tab to `SettingsView`**

In `Sources/AnglesiteApp/SettingsView.swift`, change the `TabView` body:

```swift
struct SettingsView: View {
    var body: some View {
        TabView {
            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
            SiriReadinessSettingsView()
                .tabItem { Label("Siri AI", systemImage: "sparkles") }
        }
        .frame(width: 540, height: 360)
    }
}
```

(Height bumped 320 → 360 to fit the readiness list; if `import AnglesiteIntents` is needed it goes at the top of `SettingsView.swift` too — only if the build complains.)

- [ ] **Step 3: Build both schemes to verify it links**

Run:
```bash
xcodegen generate
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **` for both.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/SiriReadinessView.swift Sources/AnglesiteApp/SettingsView.swift
git commit -m "feat(siri): Settings 'Siri AI' tab with system readiness (#236)"
```

---

### Task 7: Per-`SiteWindow` "Siri AI Readiness" command

**Files:**
- Modify: `Sources/AnglesiteApp/AnglesiteApp.swift` (hold the `ContentSpotlightIndexer`, pass to `SiteWindow`)
- Modify: `Sources/AnglesiteApp/SiteWindow.swift` (accept indexer; add toolbar button + sheet scoped to the window's site)

**Interfaces:**
- Consumes: `AnglesiteIntents.bootstrap(...) -> ContentSpotlightIndexer` (Task 4), `SiriReadinessProbes.site(...)` (Task 5), `SiriReadinessList` (Task 6).

This task has no unit test (app-target SwiftUI). Verified by the `xcodebuild` link check + the manual-check note.

- [ ] **Step 1: Hold the indexer in `AppDelegate` and pass it through**

In `Sources/AnglesiteApp/AnglesiteApp.swift`:

Near `let contentGraph = SiteContentGraph()` (line ~13), add a stored property:
```swift
    var contentIndexer: ContentSpotlightIndexer?
```
Change the bootstrap call (line ~22) from:
```swift
            await AnglesiteIntents.bootstrap(contentGraph: contentGraph)
```
to:
```swift
            self.contentIndexer = await AnglesiteIntents.bootstrap(contentGraph: contentGraph)
```
Change the `SiteWindow(...)` construction (line ~162) from:
```swift
            SiteWindow(siteID: siteID, contentGraph: appDelegate.contentGraph)
```
to:
```swift
            SiteWindow(siteID: siteID, contentGraph: appDelegate.contentGraph, contentIndexer: appDelegate.contentIndexer)
```

> If `AppDelegate` is an actor/`@MainActor`-isolated type, `self.contentIndexer = …` inside the existing `Task { … }` is already on the right actor; no extra annotation needed.

- [ ] **Step 2: Accept the indexer in `SiteWindow` and add the readiness surface**

In `Sources/AnglesiteApp/SiteWindow.swift`:

Add stored property + init param (next to `contentGraph`, lines ~20-25):
```swift
    private let contentIndexer: ContentSpotlightIndexer?

    init(siteID: String?, contentGraph: SiteContentGraph, contentIndexer: ContentSpotlightIndexer?) {
        self.siteID = siteID
        self.contentGraph = contentGraph
        self.contentIndexer = contentIndexer
        _preview = State(initialValue: PreviewModel(contentGraph: contentGraph))
    }
```

Add window state (next to the other `@State`, ~line 50):
```swift
    @State private var siriReadinessPresented = false
```

Add a toolbar button. Inside the existing `.toolbar { … }` (around line 140), add a new `ToolbarItem` (only meaningful once `site` is resolved — guard like the existing items do):
```swift
            ToolbarItem {
                Button {
                    siriReadinessPresented = true
                } label: {
                    Label("Siri AI Readiness", systemImage: "sparkles")
                }
                .help("Check whether Siri workflows are ready for this site")
                .disabled(site == nil)
            }
```

Add a sheet (next to the other `.sheet` modifiers, ~line 231). Build the per-site model from the resolved `site` + shared graph/indexer:
```swift
        .sheet(isPresented: $siriReadinessPresented) {
            if let site, let contentIndexer {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Siri AI readiness for “\(site.id)”.")
                                .font(.caption).foregroundStyle(.secondary)
                            SiriReadinessList(
                                model: SiriReadinessModel(
                                    probes: SiriReadinessProbes.site(
                                        siteID: site.id, graph: contentGraph, indexer: contentIndexer
                                    )
                                )
                            )
                        }
                        .padding()
                    }
                    .frame(minWidth: 420, minHeight: 260)
                    .navigationTitle("Siri AI Readiness")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { siriReadinessPresented = false }
                        }
                    }
                }
            }
        }
```

> If `SiriReadinessProbes` / `SiriReadinessList` aren't visible, add `import AnglesiteIntents` (for the probes) — `SiriReadinessList` is same-target. `SiteWindow` already imports `AnglesiteCore`.

- [ ] **Step 3: Build both schemes to verify it links**

Run:
```bash
xcodegen generate
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **` for both.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/AnglesiteApp.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(siri): per-site Siri AI Readiness command in site window (#236)"
```

---

### Task 8: Full verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full Swift test suite**

Run: `swift test --package-path .`
Expected: all tests pass, including the new `SiriReadiness*` suites. (Baseline was 665; this adds ~26 `@Test` cases. The MCP/apply-edit e2e tests need the sibling plugin + node — set `ANGLESITE_PLUGIN_PATH` if running them, otherwise they fail-not-skip per CLAUDE.md.)

- [ ] **Step 2: Build both schemes clean**

Run:
```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -3
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **` for both.

- [ ] **Step 3: Manual smoke (per CLAUDE.md GUI-verify gotchas)**

Launch `Anglesite`, open Settings ▸ Siri AI — confirm rows render with statuses and "Re-check" updates the timestamp. Open a site window, click the ✨ toolbar button — confirm the per-site sheet shows content-graph + Spotlight rows for that site. Watch for the known gotchas (duplicate instances, plugin-not-bundled) before trusting any FAIL row.

- [ ] **Step 4: Update issue + finish the branch**

This is where `superpowers:finishing-a-development-branch` takes over (PR to `main`, stacked per project preference). Reference #236; note #242 as the follow-up the seam migrates to.

---

## Self-Review

**Spec coverage:**
- Two surfaces (Settings tab + per-window) → Tasks 6, 7. ✓
- All seven probes → OS runtime (T2), Foundation Models (T2), App Intents (T3), View Annotations (T3), MCP bridge (T3), content-graph (T4), Spotlight (T4). ✓
- Honest `.unsupported` for unbuilt capabilities → MCP bridge (T3), device-not-eligible FM (T2), uncompiled annotations (T3). ✓
- Injectable/fake probes → every probe takes injected primitives; `SiriReadinessModel` takes `[any ReadinessProbe]`; tests use stubs/fakes. ✓
- No network; FM availability-only → `FoundationModelsProbe` reads availability, never inference (T2). ✓
- Registry uniqueness test → T5. ✓
- Logic in Core/Intents, UI thin → T1–T5 are Core/Intents with tests; T6–T7 are views verified by build. ✓
- Both schemes build → T6, T7, T8. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every run step has an expected result. The one SDK-name caveat (FoundationModels enum cases) is isolated to `LiveFoundationModelsAvailability` with an `@unknown default` and a flagged implementer note — not a placeholder.

**Type consistency:** `ReadinessFinding(id:title:level:detail:remediation:)`, `ReadinessProbe.check() async -> ReadinessFinding`, `SiriReadinessModel(probes:now:)`, `SiriReadinessProbes.system()` / `.site(siteID:graph:indexer:)`, `ContentSpotlightIndexer.indexedCounts(for:) -> IndexedCounts`, and `bootstrap(contentGraph:) async -> ContentSpotlightIndexer` are used identically across tasks. ✓
