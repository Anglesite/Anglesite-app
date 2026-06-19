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
///
/// The user-facing title is carried by the `ReadinessFinding` each probe returns, so it is not
/// part of the protocol surface — consumers read `finding.title`, never `probe.title`.
public protocol ReadinessProbe: Sendable {
    var id: String { get }
    func check() async -> ReadinessFinding
}

/// Drives a readiness surface. Mirrors `HealthModel`: `@MainActor @Observable`, injectable
/// dependencies, `recheck()` returns the `Task` so tests can await it. Probes run serially
/// for deterministic ordering.
@MainActor
@Observable
public final class SiriReadinessModel: Identifiable {
    /// Identity for SwiftUI's `.sheet(item:)`, which drives the readiness sheet off this model's
    /// existence — presenting it is impossible without a model, so the sheet can never render empty.
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    public private(set) var findings: [ReadinessFinding] = []
    public private(set) var isChecking: Bool = false
    public private(set) var lastChecked: Date?

    @ObservationIgnored private let probes: [any ReadinessProbe]
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    /// Bumped on every `recheck()`. A cancelled run uses it to tell "I was cancelled and nobody
    /// replaced me" (clear the spinner) from "a newer run superseded me" (leave its spinner alone).
    @ObservationIgnored private var generation = 0

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
        generation += 1
        let runGeneration = generation
        isChecking = true
        let probes = self.probes
        let task = Task { @MainActor [weak self] in
            var collected: [ReadinessFinding] = []
            for probe in probes {
                if Task.isCancelled { self?.cancelled(runGeneration); return }
                collected.append(await probe.check())
            }
            guard !Task.isCancelled else { self?.cancelled(runGeneration); return }
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

    /// Clear the spinner for a cancelled run — but only if no later `recheck()` has superseded it.
    /// A newer run owns `isChecking` (it set its own `true` and will `commit`), so a stale
    /// cancellation must not flip it back to `false` underneath the live run.
    private func cancelled(_ runGeneration: Int) {
        guard runGeneration == generation else { return }
        isChecking = false
    }
}
