import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

/// Regression coverage for `ProjectCleanupModel`'s `isBusy` and stale-candidate guards (PR #535,
/// issue #555). Both guards were previously asserted only by code comments — no automated
/// coverage existed.
@Suite("ProjectCleanupModel")
@MainActor
struct ProjectCleanupModelTests {
    @Test("delete refuses a candidate no longer in the current list")
    func deleteRefusesStaleCandidate() async {
        let model = ProjectCleanupModel(
            knowledgeIndex: SiteKnowledgeIndex(),
            contentGraph: SiteContentGraph(),
            gitDelete: { _, _, _ in "deadbeef" }
        )
        let staleCandidate = DeadAssetScanner.CleanupCandidate(
            id: "public/images/ghost.png",
            path: "public/images/ghost.png",
            kind: .image,
            lastModified: Date(timeIntervalSince1970: 0),
            referenceCount: 0
        )

        // `delete(_:)`'s first guard is `guard let sourceDirectory, !isBusy else { return false }`
        // — without a `configure()` call, `sourceDirectory` is nil and that guard alone would
        // short-circuit before ever reaching the stale-candidate check this test targets. Give
        // the model a real (if empty) temp directory so execution actually reaches the
        // `candidates.contains(where:)` guard below.
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        model.configure(siteID: "site-a", sourceDirectory: tempDirectory)

        // `candidates` starts empty (no scan() has run), so `staleCandidate` is not in the
        // live list — delete must refuse rather than calling gitDelete.
        let succeeded = await model.delete(staleCandidate)

        #expect(succeeded == false)
        #expect(model.deleteError?.contains("no longer in the Cleanup list") == true)
    }

    @Test("scan() is refused while delete() is in flight, and isBusy survives the refused attempt")
    func scanRefusedWhileDeleteInFlight() async throws {
        let gate = AsyncGate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("public/images"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("public/images/orphan.png"))

        let model = ProjectCleanupModel(
            knowledgeIndex: SiteKnowledgeIndex(),
            contentGraph: SiteContentGraph(),
            // Blocks until the test opens the gate, giving the test a controllable window in
            // which delete() is provably mid-flight (isBusy == true) — the seam the prior version
            // of this test lacked.
            gitDelete: { _, _, _ in await gate.waitUntilOpen(); return "deadbeef" }
        )
        model.configure(siteID: "site-a", sourceDirectory: root)
        await model.scan()
        let candidate = try #require(model.candidates.first { $0.path == "public/images/orphan.png" })

        async let deleteResult: Bool = model.delete(candidate)
        // delete() sets isBusy = true before calling gitDelete (which is now blocked on `gate`),
        // so once this loop exits, delete() is provably mid-flight.
        while !model.isBusy { await Task.yield() }

        // scan()'s guard (`guard ..., !isBusy else { return }`) fires before scan() ever touches
        // isBusy itself, so isBusy should still read exactly what delete() left it at. If that
        // guard were removed, this scan() would run to completion (fast — an empty temp-dir
        // knowledgeIndex.rebuild) and its own `defer { isBusy = false }` would flip isBusy back to
        // false before this await returns, failing the assertion below — a real positive signal
        // for the guard, not just idempotency.
        await model.scan()
        #expect(model.isBusy == true)

        await gate.open()
        let succeeded = await deleteResult
        #expect(succeeded == true)
        #expect(model.isBusy == false)
    }
}

/// Minimal manually-resettable async gate: lets a test hold an awaited closure open until it
/// explicitly releases it, to create a controllable "still in flight" window.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func waitUntilOpen() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
