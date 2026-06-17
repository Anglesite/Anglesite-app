import Foundation
import AnglesiteCore

/// Robust startup waiting for the MCP / apply-edit end-to-end tests, which spawn the *real* plugin
/// Node server. Cold startup is fast (<1 s) when healthy, but a broken plugin install — e.g. a
/// missing native dep like `sharp`, which `server/apply-edit-dispatcher.mjs` imports eagerly — makes
/// the server crash on load before it ever listens. Polling the connect/handshake alone can't tell
/// "still booting" from "already dead", so it would burn the entire timeout budget and then report
/// an opaque transport error (`.sessionLost`) instead of the real crash.
///
/// `awaitReady` races the readiness operation against the supervised process's exit: if the process
/// dies first, it throws `ServerExited` carrying the captured stderr, surfacing the real cause
/// immediately.
public enum E2EServer {
    /// The spawned server process exited before it became ready. Carries the captured stderr so the
    /// real failure (e.g. `Cannot find package 'sharp'`) is visible in the test output.
    public struct ServerExited: Error, CustomStringConvertible {
        public let reason: ProcessSupervisor.ExitReason
        public let stderr: String

        public init(reason: ProcessSupervisor.ExitReason, stderr: String) {
            self.reason = reason
            self.stderr = stderr
        }

        public var description: String {
            """
            MCP server process exited (\(reason)) before becoming ready.
            --- captured stderr ---
            \(stderr.isEmpty ? "(no stderr captured)" : stderr)
            """
        }
    }

    /// Run `readiness` (typically a connect/handshake poll), but abort the moment the supervised
    /// `handle` process exits — throwing `ServerExited` with the captured stderr instead of letting
    /// the poll spin until `timeout`. The budget can therefore be generous (real cold starts vary)
    /// without making a *dead* server slow to diagnose: it fails in the time the process takes to
    /// crash, not the time the budget allows.
    ///
    /// `InProcessBackend` drains the stdout/stderr pipes before resuming exit waiters, so the stderr
    /// snapshot taken after `waitForExit` is guaranteed to include the crash output.
    public static func awaitReady(
        handle: ProcessSupervisor.Handle,
        supervisor: ProcessSupervisor,
        logCenter: LogCenter,
        timeout: TimeInterval = 60,
        readiness: @Sendable @escaping () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await readiness() }

            group.addTask {
                let reason = await supervisor.waitForExit(handle)
                // `waitForExit` returns `.terminated` immediately when *this* task is cancelled
                // (readiness already won) — don't misreport that as a crash.
                if Task.isCancelled { return }
                let stderr = await logCenter.snapshot()
                    .filter { $0.source == handle.source && $0.stream == .stderr }
                    .map(\.text)
                    .joined(separator: "\n")
                throw ServerExited(reason: reason, stderr: stderr)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                throw ServerExited(
                    reason: .terminated,
                    stderr: "timed out after \(timeout)s waiting for the server to become ready"
                )
            }

            defer { group.cancelAll() }
            // First task to finish decides the outcome: readiness success returns, a crash or
            // timeout throws.
            try await group.next()
        }
    }
}
