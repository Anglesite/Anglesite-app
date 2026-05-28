import Foundation

/// One `HelperService` per `NSXPCConnection`. Owns the spawned child processes for that
/// connection. Connection teardown calls `shutdownAll` so no orphan children survive the app.
actor HelperService: NSObject {
    private let connection: NSXPCConnection
    private var children: [UUID: ChildProcess] = [:]

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    /// Streaming proxy back to the app. Lazily resolved on first use.
    private var clientProxy: HelperClientProtocol? {
        connection.remoteObjectProxyWithErrorHandler { error in
            // Connection died mid-stream. Cleanup is driven by invalidationHandler in main.swift.
        } as? HelperClientProtocol
    }

    func connectionInvalidated() async {
        await shutdownAll(timeout: 2)
    }

    /// Decode a SpawnSpec and prep the Process. Resolving the bookmark (if any) lives here.
    private func resolveSpawn(_ spec: SpawnSpec) throws -> (Process, URL?) {
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        if let env = spec.environment { process.environment = env }

        var scopedURL: URL? = nil
        if let bookmark = spec.workingDirectoryBookmark {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard url.startAccessingSecurityScopedResource() else {
                throw NSError(
                    domain: "AnglesiteHelper",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "bookmark resolution failed"]
                )
            }
            scopedURL = url
            process.currentDirectoryURL = url
        } else if let cwd = spec.workingDirectory {
            process.currentDirectoryURL = cwd
        }

        return (process, scopedURL)
    }

    // MARK: - AnglesiteHelperProtocol (via objc shim — see end of file)

    func runOneShotImpl(specData: Data) async throws -> Data {
        let spec = try JSONDecoder().decode(SpawnSpec.self, from: specData)
        let (process, scopedURL) = try resolveSpawn(spec)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        async let outData = Task.detached { stdoutPipe.fileHandleForReading.readDataToEndOfFile() }.value
        async let errData = Task.detached { stderrPipe.fileHandleForReading.readDataToEndOfFile() }.value
        let (out, err) = await (outData, errData)
        process.waitUntilExit()

        scopedURL?.stopAccessingSecurityScopedResource()

        let result = ProcessResult(stdout: out, stderr: err, exitCode: process.terminationStatus)
        return try JSONEncoder().encode(result)
    }

    func launchImpl(specData: Data) async throws -> Data {
        let spec = try JSONDecoder().decode(SpawnSpec.self, from: specData)
        let (process, scopedURL) = try resolveSpawn(spec)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdinFH: FileHandle? = nil
        if spec.stdinPipe {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            stdinFH = stdinPipe.fileHandleForWriting
        }

        try process.run()
        let pid = process.processIdentifier
        let handle = SpawnedProcessHandle(pid: pid)

        let child = ChildProcess(
            id: handle.id,
            process: process,
            stdinFH: stdinFH,
            scopedURL: scopedURL,
            source: spec.logSource
        )
        children[handle.id] = child

        // Stream stdout/stderr line-by-line via the client proxy.
        child.startStreaming(
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            proxy: clientProxy,
            onExit: { [weak self] code in
                Task { await self?.reapChild(id: handle.id, exitCode: code) }
            }
        )

        return try JSONEncoder().encode(handle)
    }

    private func reapChild(id: UUID, exitCode: Int32) async {
        guard let child = children.removeValue(forKey: id) else { return }
        child.scopedURL?.stopAccessingSecurityScopedResource()
        clientProxy?.processExited(handleID: id.uuidString, status: exitCode)
    }

    func terminateImpl(handleData: Data, timeout: TimeInterval) async {
        guard let handle = try? JSONDecoder().decode(SpawnedProcessHandle.self, from: handleData),
              let child = children[handle.id] else { return }
        child.process.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while child.process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if child.process.isRunning {
            kill(child.process.processIdentifier, SIGKILL)
        }
    }

    func shutdownAll(timeout: TimeInterval) async {
        let snapshot = Array(children.values)
        await withTaskGroup(of: Void.self) { group in
            for child in snapshot {
                group.addTask {
                    child.process.terminate()
                    let deadline = Date().addingTimeInterval(timeout)
                    while child.process.isRunning && Date() < deadline {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    if child.process.isRunning {
                        kill(child.process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
        for (id, child) in children {
            child.scopedURL?.stopAccessingSecurityScopedResource()
            children.removeValue(forKey: id)
        }
    }

    func writeStdinImpl(handleData: Data, bytes: Data) async throws {
        let handle = try JSONDecoder().decode(SpawnedProcessHandle.self, from: handleData)
        guard let child = children[handle.id], let fh = child.stdinFH else {
            throw NSError(
                domain: "AnglesiteHelper",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "no stdin pipe for this handle"]
            )
        }
        try fh.write(contentsOf: bytes)
    }
}

/// `NSXPCConnection` requires an `@objc` class as the `exportedObject`. The actor above does
/// the real work; this shim adapts the @objc reply-handler signature into async/await.
extension HelperService: AnglesiteHelperProtocol {
    nonisolated func runOneShot(specData: Data, reply: @escaping (Data?, Error?) -> Void) {
        Task {
            do { reply(try await runOneShotImpl(specData: specData), nil) }
            catch { reply(nil, error) }
        }
    }

    nonisolated func launch(specData: Data, reply: @escaping (Data?, Error?) -> Void) {
        Task {
            do { reply(try await launchImpl(specData: specData), nil) }
            catch { reply(nil, error) }
        }
    }

    nonisolated func terminate(handleData: Data, timeout: TimeInterval, reply: @escaping () -> Void) {
        Task { await terminateImpl(handleData: handleData, timeout: timeout); reply() }
    }

    nonisolated func shutdownAll(timeout: TimeInterval, reply: @escaping () -> Void) {
        Task { await shutdownAll(timeout: timeout); reply() }
    }

    nonisolated func writeStdin(handleData: Data, bytes: Data, reply: @escaping (Error?) -> Void) {
        Task {
            do { try await writeStdinImpl(handleData: handleData, bytes: bytes); reply(nil) }
            catch { reply(error) }
        }
    }
}

/// One spawned child's local bookkeeping. Lives only inside `HelperService.children`.
final class ChildProcess {
    let id: UUID
    let process: Process
    let stdinFH: FileHandle?
    let scopedURL: URL?
    let source: String

    init(id: UUID, process: Process, stdinFH: FileHandle?, scopedURL: URL?, source: String) {
        self.id = id
        self.process = process
        self.stdinFH = stdinFH
        self.scopedURL = scopedURL
        self.source = source
    }

    func startStreaming(
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        proxy: HelperClientProtocol?,
        onExit: @escaping (Int32) -> Void
    ) {
        let pid = process.processIdentifier
        let src = source

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
                proxy?.stdoutLine(String(line), pid: pid, source: src)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
                proxy?.stderrLine(String(line), pid: pid, source: src)
            }
        }

        process.terminationHandler = { proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            onExit(proc.terminationStatus)
        }
    }
}
