import Foundation

/// XPC interface implemented by `AnglesiteHelper` and called from `XPCBackend` (the MAS app side).
///
/// All payloads cross the XPC boundary as `Data` containing JSON-encoded `SpawnSpec` /
/// `ProcessResult` / `SpawnedProcessHandle`. Keeping the `@objc` surface minimal means the
/// generated proxy stubs are predictable; the richer Swift types stay in Swift on both sides.
@objc public protocol AnglesiteHelperProtocol {
    /// One-shot spawn. `specData` is `JSONEncoder().encode(SpawnSpec)`.
    /// Reply `resultData` is `JSONEncoder().encode(ProcessResult)`, or `nil` if `error` is set.
    func runOneShot(specData: Data, reply: @escaping (Data?, Error?) -> Void)

    /// Long-lived spawn. Same encoding as `runOneShot` for the spec; reply is
    /// `JSONEncoder().encode(SpawnedProcessHandle)`. Stdout/stderr arrive on the client's
    /// `HelperClientProtocol` interface (registered via `NSXPCConnection.exportedObject`).
    func launch(specData: Data, reply: @escaping (Data?, Error?) -> Void)

    /// SIGTERM -> SIGKILL after `timeout`. `handleData` is the encoded `SpawnedProcessHandle`.
    func terminate(handleData: Data, timeout: TimeInterval, reply: @escaping () -> Void)

    /// Stop every process this helper instance is tracking. Called on connection
    /// invalidation as part of teardown.
    func shutdownAll(timeout: TimeInterval, reply: @escaping () -> Void)

    /// Write `bytes` to the spawned process's stdin. Replies with a non-nil `error` if the
    /// spawn didn't set `stdinPipe: true`. (Live `FileHandle`s can't cross XPC, so MAS stdin
    /// writes route through this call rather than the in-process `stdinHandle` seam.)
    func writeStdin(handleData: Data, bytes: Data, reply: @escaping (Error?) -> Void)
}

/// Inbound interface the helper calls back into the app for streaming events.
/// Registered on the `NSXPCConnection` via `exportedInterface` + `exportedObject` on the app side.
@objc public protocol HelperClientProtocol {
    /// A line of stdout from a spawned process. `pid` identifies which child; `source` is the
    /// `SpawnSpec.logSource` for tag routing into `LogCenter`.
    func stdoutLine(_ line: String, pid: Int32, source: String)

    /// Same shape for stderr.
    func stderrLine(_ line: String, pid: Int32, source: String)

    /// Process has exited. Final code; the supervisor uses this to resume `waitForExit`.
    /// `handleID` is the `SpawnedProcessHandle.id` UUID encoded as a string (XPC `@objc`
    /// can't pass `UUID` directly).
    func processExited(handleID: String, status: Int32)
}

/// XPC service name. Matches `CFBundleIdentifier` of `AnglesiteHelper.xpc/Contents/Info.plist`.
public let kAnglesiteHelperServiceName = "dev.anglesite.app.mas.helper"
