import Foundation

/// Dials a guest vsock port and returns a `FileHandle` for the bidirectional byte stream.
/// Production passes `{ port in try container.dialVsock(port: port) }`; tests pass a loopback
/// (socketpair) dialer. This closure is the ONLY framework-bound part of the proxy.
public typealias VsockDialer = @Sendable (_ guestPort: UInt32) async throws -> FileHandle

/// Host-side proxy: listens on `127.0.0.1:0` and, for each accepted TCP connection, dials the
/// guest vsock port and splices the two `FileHandle`s bidirectionally until either side closes.
/// This is the seam that lets `WKWebView` load `http://127.0.0.1:<port>` and `MCPClient` connect
/// over plain HTTP while the actual server runs inside the VM, reachable only over vsock.
public actor VsockTCPProxy {
    private let guestPort: UInt32
    private let dial: VsockDialer
    /// Reports a failed `dial(guestPort)` (e.g. `container.dialVsock` unable to reach the guest).
    /// Without this, `handleAccepted`'s catch silently closed the TCP side with zero diagnostic
    /// trail — indistinguishable, from the client's perspective, from a slow/hung guest process:
    /// both surface as `NSURLErrorNetworkConnectionLost` on the polling `URLSession` (see #69).
    private let onDialError: @Sendable (Error) -> Void
    /// Diagnostic-only lifecycle events (see #69): "accepted" when a host TCP connection lands,
    /// "dial-ok" when `dial(guestPort)` returns without throwing. Together with `onDialError` these
    /// pin down exactly which stage — accept, dial, or the byte-level splice — a silently-broken
    /// connection actually failed at, instead of every failure looking identical from the outside
    /// (`NSURLErrorNetworkConnectionLost` on the polling `URLSession`).
    private let onEvent: @Sendable (String) -> Void
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ProxyConnection] = []

    public init(
        guestPort: UInt32,
        dial: @escaping VsockDialer,
        onDialError: @escaping @Sendable (Error) -> Void = { _ in },
        onEvent: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.guestPort = guestPort
        self.dial = dial
        self.onDialError = onDialError
        self.onEvent = onEvent
    }

    /// Bind + listen on 127.0.0.1:0, install the accept handler, and return the loopback URL with
    /// the OS-assigned port. Throws `LocalContainerError.bootFailed` on any socket error.
    public func start() throws -> URL {
        guard listenFD < 0 else { throw LocalContainerError.bootFailed("already started") }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalContainerError.bootFailed("socket() failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                                   // OS-assigned
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRC == 0 else { close(fd); throw LocalContainerError.bootFailed("bind() failed") }
        guard listen(fd, 16) == 0 else { close(fd); throw LocalContainerError.bootFailed("listen() failed") }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = UInt16(bigEndian: bound.sin_port)

        self.listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd)
        source.setEventHandler { [weak self] in
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else { return }
            Task { [weak self] in
                guard let self else { close(conn); return }
                await self.handleAccepted(conn)
            }
        }
        source.resume()
        self.acceptSource = source

        return URL(string: "http://127.0.0.1:\(port)")!
    }

    public func stop() {
        // cancel() is async wrt GCD delivery, so one more handler invocation may fire after this;
        // accept() on the closed fd returns EBADF (<0), which the handler's `guard conn >= 0` catches cleanly.
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        for c in connections { c.close() }
        connections.removeAll()
    }

    private func handleAccepted(_ tcpFD: Int32) async {
        onEvent("accepted")
        let tcp = FileHandle(fileDescriptor: tcpFD, closeOnDealloc: true)
        do {
            let guest = try await dial(guestPort)
            onEvent("dial-ok")
            let conn = ProxyConnection(tcp: tcp, guest: guest, onEvent: onEvent)
            connections.append(conn)
            conn.start(onClose: { [weak self] c in Task { await self?.removeConnection(c) } })
        } catch {
            onDialError(error)
            try? tcp.close()
        }
    }

    private func removeConnection(_ conn: ProxyConnection) {
        connections.removeAll { $0 === conn }
    }

    /// Number of live connections. Exposed for testing only.
    var connectionCount: Int { connections.count }
}

/// One spliced TCP↔vsock pair. Uses each handle's `readabilityHandler` to detect when bytes are
/// available, then copies them via `FileHandle`'s own `availableData`/`write(contentsOf:)` (see
/// `pump` below for why a lock, not raw POSIX syscalls, is what makes this safe); an empty read
/// (EOF) or unrecoverable write error tears the pair down.
final class ProxyConnection: @unchecked Sendable {
    private let tcp: FileHandle
    private let guest: FileHandle
    private let lock = NSLock()
    private var closed = false
    /// Called exactly once, after the connection closes, with `self` as the argument.
    private var onClose: (@Sendable (_ conn: ProxyConnection) -> Void)?
    private let onEvent: @Sendable (String) -> Void

    init(tcp: FileHandle, guest: FileHandle, onEvent: @escaping @Sendable (String) -> Void = { _ in }) {
        self.tcp = tcp
        self.guest = guest
        self.onEvent = onEvent
    }

    /// Begin pumping bytes in both directions. `onClose` is provided here (set-once, private) so
    /// there is no mutable public var window between construction and the first read handler firing.
    func start(onClose: @escaping @Sendable (ProxyConnection) -> Void) {
        self.onClose = onClose
        pump(from: tcp, to: guest, label: "tcp->guest")
        pump(from: guest, to: tcp, label: "guest->tcp")
    }

    /// Reads from `from` and forwards to `to` whenever `from` reports readable. Each direction's
    /// handler runs on that `FileHandle`'s own dispatch source, so the two directions of one
    /// connection can fire concurrently on different threads: an EOF on one side calls `close()`,
    /// which can run while the other side's handler is mid-flight. `FileHandle.availableData` and
    /// `.write(contentsOf:)` raise an Objective-C `NSException` (not a Swift error — `try?` can't
    /// catch it) when invoked on a handle another thread is concurrently invalidating via `.close()`
    /// — that previously crashed the whole app via `abort()`. Holding `lock` across the ENTIRE
    /// read-then-write (not just an initial "already closed?" check), and having `close()` acquire
    /// the same lock before touching either handle, means a read/write here and a close() can never
    /// overlap: whichever gets the lock first runs to completion before the other proceeds. This
    /// serializes the two directions of a single connection against each other (and against close()),
    /// trading a small amount of throughput for correctness — an acceptable cost for a dev-preview
    /// proxy. (An earlier version of this method used raw POSIX `read`/`write` on captured fds
    /// instead of a lock; that also closed the race, but pulled in a Swift/Foundation overlay symbol
    /// CI's older Xcode toolchain doesn't ship, failing `swift test`'s dlopen entirely — see #69.)
    private func pump(from: FileHandle, to: FileHandle, label: String) {
        from.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.closed else { return }

            let data = handle.availableData
            if data.isEmpty {
                self.onEvent("\(label) EOF")
                self.closeLocked()
                return
            }
            do {
                try to.write(contentsOf: data)
            } catch {
                self.onEvent("\(label) write error: \(error)")
                self.closeLocked()
            }
        }
    }

    func close() {
        lock.lock()
        closeLocked()
        lock.unlock()
    }

    /// Idempotent teardown. Must be called with `lock` held. `onClose` is invoked here (not after
    /// unlocking): it only ever does `Task { await self?.removeConnection(c) }`-shaped work, which
    /// schedules and returns immediately, so calling it while holding this instance's own lock
    /// cannot deadlock or re-enter this lock.
    private func closeLocked() {
        guard !closed else { return }
        closed = true
        tcp.readabilityHandler = nil
        guest.readabilityHandler = nil
        try? tcp.close()
        try? guest.close()
        onClose?(self)
    }
}
