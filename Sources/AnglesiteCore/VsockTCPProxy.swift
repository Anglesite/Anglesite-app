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
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ProxyConnection] = []

    public init(guestPort: UInt32, dial: @escaping VsockDialer) {
        self.guestPort = guestPort
        self.dial = dial
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
        let tcp = FileHandle(fileDescriptor: tcpFD, closeOnDealloc: true)
        do {
            let guest = try await dial(guestPort)
            let conn = ProxyConnection(tcp: tcp, guest: guest)
            connections.append(conn)
            conn.start(onClose: { [weak self] c in Task { await self?.removeConnection(c) } })
        } catch {
            try? tcp.close()
        }
    }

    private func removeConnection(_ conn: ProxyConnection) {
        connections.removeAll { $0 === conn }
    }

    /// Number of live connections. Exposed for testing only.
    var connectionCount: Int { connections.count }
}

/// One spliced TCP↔vsock pair. Uses each handle's `readabilityHandler` to copy bytes both ways;
/// an empty read (EOF) tears the pair down.
final class ProxyConnection: @unchecked Sendable {
    private let tcp: FileHandle
    private let guest: FileHandle
    // Captured once at init, before either direction's readability handler can fire — every
    // subsequent read/write goes through these raw descriptors, never through NSFileHandle's
    // ObjC read/write/fileDescriptor accessors (see `pump` below for why).
    private let tcpFD: Int32
    private let guestFD: Int32
    private let lock = NSLock()
    private var closed = false
    /// Called exactly once, after the connection closes, with `self` as the argument.
    /// Invoked outside the lock to avoid re-entrancy / deadlock.
    private var onClose: (@Sendable (_ conn: ProxyConnection) -> Void)?

    init(tcp: FileHandle, guest: FileHandle) {
        self.tcp = tcp
        self.guest = guest
        self.tcpFD = tcp.fileDescriptor
        self.guestFD = guest.fileDescriptor
    }

    /// Begin pumping bytes in both directions. `onClose` is provided here (set-once, private) so
    /// there is no mutable public var window between construction and the first read handler firing.
    func start(onClose: @escaping @Sendable (ProxyConnection) -> Void) {
        self.onClose = onClose
        pump(from: tcp, fromFD: tcpFD, toFD: guestFD)
        pump(from: guest, fromFD: guestFD, toFD: tcpFD)
    }

    /// Reads from `fromFD` and forwards to `toFD` whenever `from` reports readable, entirely via raw
    /// POSIX `read`/`write` on the captured descriptors — never via `FileHandle.availableData`,
    /// `.write(contentsOf:)`, or `.fileDescriptor`. Each direction's handler runs on that FileHandle's
    /// own dispatch source, so the two directions of one connection execute concurrently: an EOF on
    /// one side calls `close()`, which can run while the other side's handler is already mid-flight.
    /// Those NSFileHandle accessors raise an Objective-C `NSException` (not a Swift error, so `try?`
    /// can't catch it) when touched on a handle the other thread is concurrently closing — that
    /// crashed the whole app via `abort()`. Raw syscalls on a captured fd number just return an
    /// ordinary POSIX error in the same situation.
    private func pump(from: FileHandle, fromFD: Int32, toFD: Int32) {
        from.readabilityHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let alreadyClosed = self.closed
            self.lock.unlock()
            if alreadyClosed { return }

            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let n = buffer.withUnsafeMutableBytes { read(fromFD, $0.baseAddress, $0.count) }
            if n <= 0 {
                if n < 0 && errno == EINTR { return }  // transient; retry on the next readability callback
                self.close()
                return
            }

            if !Self.writeAll(Data(buffer[0..<n]), to: toFD) {
                self.close()
            }
        }
    }

    /// Writes every byte of `data` to `fd`, retrying on `EINTR` and partial writes. Returns `false`
    /// (rather than throwing/raising) on any unrecoverable error, e.g. `EPIPE`/`ECONNRESET` when the
    /// peer has closed its end.
    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Bool in
            var offset = 0
            let total = rawBuffer.count
            while offset < total {
                let n = rawBuffer.baseAddress!.advanced(by: offset)
                    .withMemoryRebound(to: UInt8.self, capacity: total - offset) { ptr in
                        write(fd, ptr, total - offset)
                    }
                if n > 0 {
                    offset += n
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    func close() {
        // Idempotent: only the first caller transitions closed → true.
        // Handlers are cleared + fds closed under the lock; onClose invoked AFTER unlock (never under the lock).
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        tcp.readabilityHandler = nil
        guest.readabilityHandler = nil
        try? tcp.close()
        try? guest.close()
        lock.unlock()

        onClose?(self)
    }
}
