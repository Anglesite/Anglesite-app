import Foundation

/// The coarse milestone a dev-server startup is currently at. Drives both the progress bar's fill
/// range and the curated message shown beneath it.
public enum StartupPhase: String, Sendable, Equatable, CaseIterable {
    case idle
    case launching
    case building
    case connecting
    case ready
    case failed

    /// Forward-only ordering. The estimator only ever advances to a higher-ranked active phase.
    /// Note: `.failed` and `.idle` are reset directly in `ingest(runtimeState:)` and never reached
    /// through the forward-only `enter(_:at:)`, so their rank ordering relative to `.ready` is not
    /// load-bearing.
    var rank: Int {
        switch self {
        case .idle:       return 0
        case .launching:  return 1
        case .building:   return 2
        case .connecting: return 3
        case .ready:      return 4
        case .failed:     return 5
        }
    }

    /// `[start, cap]` fraction band the bar occupies while in this phase. The smooth fill eases
    /// from `start` toward `cap` but only the next real anchor crosses into the following band.
    var fillRange: (start: Double, cap: Double) {
        switch self {
        case .idle, .failed: return (0, 0)
        case .launching:     return (0.0, 0.15)
        case .building:      return (0.15, 0.55)
        case .connecting:    return (0.55, 0.90)
        case .ready:         return (1.0, 1.0)
        }
    }

    public var message: String {
        switch self {
        case .idle, .failed, .ready: return ""
        case .launching:  return "Starting dev server…"
        case .building:   return "Building site…"
        case .connecting: return "Connecting to preview…"
        }
    }
}

/// Pure, time-base-agnostic state machine that turns startup signals into a determinate progress
/// fraction and a phase message. It is driven entirely by its caller — runtime-state changes, the
/// site's `astro` stdout lines, and periodic `tick`s — with timestamps supplied as parameters, so
/// it carries no clock and is trivially testable. The `StartupProgressModel` (AnglesiteApp) owns
/// the clock, the `LogCenter` subscription, and persistence.
///
/// Fill is anchored by real milestones and eased between them using a `StartupProfile`: within a
/// phase the fraction approaches — but never reaches — that phase's cap, so the bar keeps inching
/// on overrun and only a genuine anchor completes a segment. `.ready` jumps to `1.0`.
public struct StartupProgressEstimator: Sendable, Equatable {
    public private(set) var phase: StartupPhase = .idle
    public private(set) var fraction: Double = 0

    private let profile: StartupProfile
    private var phaseEnteredAt: TimeInterval = 0
    private var anchorTimes: [StartupPhase: TimeInterval] = [:]

    /// How sharply the fill approaches the cap. At `elapsed == expectedSegment` the bar is ~92% of
    /// the way across the band; it asymptotes to (but never reaches) the cap thereafter.
    private static let easeK = 2.5
    private static let fractionEpsilon = 0.0001

    public init(profile: StartupProfile = .default) {
        self.profile = profile
    }

    public var message: String { phase.message }

    public var isActive: Bool {
        phase == .launching || phase == .building || phase == .connecting
    }

    /// After a successful startup, the measured per-segment durations — for persisting back to the
    /// `StartupTimingStore`. `nil` until `.ready`. Missing intermediate anchors collapse to zero-
    /// length segments (e.g. a URL line that arrived before any other astro output).
    public var completedProfile: StartupProfile? {
        guard phase == .ready,
              let tLaunch = anchorTimes[.launching],
              let tReady = anchorTimes[.ready] else { return nil }
        let tBuild = anchorTimes[.building] ?? tLaunch
        let tConn = anchorTimes[.connecting] ?? tBuild
        return StartupProfile(
            launchingToBuilding: max(tBuild - tLaunch, 0),
            buildingToConnecting: max(tConn - tBuild, 0),
            connectingToReady: max(tReady - tConn, 0)
        )
    }

    /// Drive launching/ready/failed anchors off the runtime's state machine.
    public mutating func ingest(runtimeState: SiteRuntimeState, at now: TimeInterval) {
        switch runtimeState {
        case .starting:
            enter(.launching, at: now)
        case .ready:
            enter(.ready, at: now)
        case .failed:
            // A crash *after* a successful start is a runtime concern, not a startup one — the
            // error pane handles it; don't clobber the completed bar.
            guard phase != .ready else { return }
            phase = .failed
            fraction = 0
        case .idle:
            guard phase != .ready else { return }
            phase = .idle
            fraction = 0
            anchorTimes = [:]
        }
    }

    /// Drive building/connecting anchors off the site's `astro` stdout. The caller is responsible
    /// for filtering to the `astro:<siteID>` stdout stream before calling.
    public mutating func ingest(logText: String, at now: TimeInterval) {
        guard isActive else { return }
        if AstroDevServer.parseReadyURL(logText) != nil {
            enter(.connecting, at: now)
        } else {
            enter(.building, at: now)
        }
    }

    /// Ease the fraction toward the current phase's cap, paced by the expected segment duration.
    /// No-op once the startup is no longer active.
    public mutating func tick(now: TimeInterval) {
        guard isActive else { return }
        let (start, cap) = phase.fillRange
        let expected = max(expectedSegment(for: phase), 0.05)
        let r = max(now - phaseEnteredAt, 0) / expected
        let eased = 1 - exp(-Self.easeK * r)               // 0 at r=0, →1, never 1
        let target = start + (cap - start) * eased
        // Monotonic, and strictly below the cap so only a real anchor can cross into the next band.
        fraction = min(max(fraction, target), cap - Self.fractionEpsilon)
    }

    // MARK: - Internals

    /// Expected duration of the segment we wait through *while in* `phase`.
    private func expectedSegment(for phase: StartupPhase) -> TimeInterval {
        switch phase {
        case .launching:  return profile.launchingToBuilding
        case .building:   return profile.buildingToConnecting
        case .connecting: return profile.connectingToReady
        default:          return 0
        }
    }

    /// Advance to a higher-ranked phase, recording its anchor time and snapping the fraction up to
    /// the new band's start. Lower-or-equal ranks are ignored (forward-only).
    private mutating func enter(_ newPhase: StartupPhase, at now: TimeInterval) {
        guard newPhase.rank > phase.rank else { return }
        anchorTimes[newPhase] = now
        phaseEnteredAt = now
        phase = newPhase
        fraction = max(fraction, newPhase.fillRange.start)
    }
}
