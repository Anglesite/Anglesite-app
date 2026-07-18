import Foundation
import Testing
@testable import AnglesiteCore

private actor PublishProbe {
    private(set) var calls = 0
    var result: InvisiblePublishQueue.Result

    init(result: InvisiblePublishQueue.Result = .succeeded(url: URL(string: "https://example.com") ?? URL(fileURLWithPath: "/"))) {
        self.result = result
    }

    func publish() -> InvisiblePublishQueue.Result {
        calls += 1
        return result
    }
}

private actor GatedPublishProbe {
    private(set) var calls = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?

    func publish() async -> InvisiblePublishQueue.Result {
        calls += 1
        if calls == 1 {
            await withCheckedContinuation { firstContinuation = $0 }
        }
        return .succeeded(url: URL(string: "https://example.com") ?? URL(fileURLWithPath: "/"))
    }

    func waitUntilFirstPublishStarts() async {
        while calls == 0 { await Task.yield() }
    }

    func finishFirstPublish() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

/// A manually-triggered stand-in for `InvisiblePublishQueue`'s debounce timer. Each
/// `recordEdit()` that schedules a debounce parks here instead of racing a real `Task.sleep`
/// against the queue actor's own scheduling — under CI's parallel-suite load, that race let a
/// stalled scheduler either miss the debounce window entirely or let it fire mid-edit-sequence
/// and split edits into two publishes, even with a generous real-time margin (#762).
///
/// A test drives it by waiting for `armedCount()` to reach the number of `recordEdit()` calls it
/// made, then calling `release()`. Stale timers from edits that were superseded by a later one
/// stay armed (this gate doesn't model cancellation) and get released too, but that's harmless:
/// `InvisiblePublishQueue.beginPublish()` guards on `publishTask == nil`, so only the first
/// released timer actually starts a publish.
private actor ManualDebounceGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep() async {
        await withCheckedContinuation { continuations.append($0) }
    }

    func armedCount() -> Int { continuations.count }

    func release() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

// Serialized: each test drives the queue's debounce scheduling, and running them concurrently
// with each other amplifies scheduler starvation under `swift test --parallel` on loaded CI
// runners (#762).
@Suite("Invisible publish queue", .serialized)
struct InvisiblePublishQueueTests {
    @Test("idle edits debounce into one publish")
    func debouncesEdits() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = PublishProbe()
        let gate = ManualDebounceGate()
        let queue = InvisiblePublishQueue(
            configDirectory: directory,
            debounce: .milliseconds(250),
            publisher: { await probe.publish() },
            sleep: { _ in await gate.sleep() }
        )

        await queue.start(isOnline: true)
        await queue.recordEdit()
        await queue.recordEdit()
        await queue.recordEdit()
        // All three edits are on the actor before any debounce "elapses" — release only once
        // every recordEdit() has armed its timer, so coalescing is verified by construction
        // rather than by racing real sleeps against actor scheduling (#762).
        try await waitUntil { await gate.armedCount() == 3 }
        await gate.release()
        try await waitUntil {
            let calls = await probe.calls
            let pending = await queue.hasPendingPublish()
            return calls == 1 && !pending
        }

        #expect(await probe.calls == 1)
        #expect(await queue.currentState() == .idle)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(InvisiblePublishQueue.filename).path
        ))
    }

    @Test("offline edits persist and drain after reconnect, including across queue recreation")
    func offlineQueueDrains() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstProbe = PublishProbe()
        let first = InvisiblePublishQueue(
            configDirectory: directory,
            debounce: .milliseconds(10),
            publisher: { await firstProbe.publish() }
        )
        await first.start(isOnline: false)
        await first.recordEdit()

        #expect(await firstProbe.calls == 0)
        #expect(await first.currentState() == .queuedOffline)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(InvisiblePublishQueue.filename).path
        ))
        await first.stop()

        let secondProbe = PublishProbe()
        let restored = InvisiblePublishQueue(
            configDirectory: directory,
            debounce: .milliseconds(10),
            publisher: { await secondProbe.publish() }
        )
        await restored.start(isOnline: false)
        #expect(await restored.hasPendingPublish())
        await restored.setOnline(true)
        try await waitUntil {
            let calls = await secondProbe.calls
            let pending = await restored.hasPendingPublish()
            return calls == 1 && !pending
        }

        #expect(await restored.currentState() == .idle)
    }

    @Test("security blocks remain durably queued")
    func securityBlockStaysPending() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = PublishProbe(result: .blocked(failureCount: 2))
        let gate = ManualDebounceGate()
        let queue = InvisiblePublishQueue(
            configDirectory: directory,
            debounce: .milliseconds(10),
            publisher: { await probe.publish() },
            sleep: { _ in await gate.sleep() }
        )
        await queue.start(isOnline: true)
        await queue.recordEdit()
        try await waitUntil { await gate.armedCount() == 1 }
        await gate.release()
        try await waitUntil { await queue.currentState() == .blocked(failureCount: 2) }

        #expect(await queue.hasPendingPublish())
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(InvisiblePublishQueue.filename).path
        ))
    }

    @Test("an edit during publishing schedules a second generation")
    func editDuringPublishRunsAgain() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = GatedPublishProbe()
        let gate = ManualDebounceGate()
        let queue = InvisiblePublishQueue(
            configDirectory: directory,
            debounce: .milliseconds(20),
            publisher: { await probe.publish() },
            sleep: { _ in await gate.sleep() }
        )
        await queue.start(isOnline: true)
        await queue.recordEdit()
        try await waitUntil { await gate.armedCount() == 1 }
        await gate.release()
        await probe.waitUntilFirstPublishStarts()
        await queue.recordEdit()
        await probe.finishFirstPublish()

        // The completed publish covered the pre-edit generation, so it schedules a second
        // debounce for the edit that landed mid-publish — release that one too.
        try await waitUntil { await gate.armedCount() == 1 }
        await gate.release()

        try await waitUntil {
            let calls = await probe.calls
            let pending = await queue.hasPendingPublish()
            return calls == 2 && !pending
        }
        #expect(await queue.currentState() == .idle)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("InvisiblePublishQueueTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Polls `condition` until it holds or `timeout` elapses. The deadline is
    /// deliberately generous: it only bounds how long a genuine failure hangs,
    /// while a passing test returns as soon as the condition is met — a tight
    /// deadline just makes the suite flaky under parallel CI load (#762).
    private func waitUntil(
        timeout: Duration = .seconds(30),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else {
                Issue.record("timed out waiting for invisible-publish state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
