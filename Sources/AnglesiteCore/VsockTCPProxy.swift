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
            conn.onClose = { [weak self] c in
                Task { await self?.removeConnection(c) }
            }
            connections.append(conn)
            conn.start()
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
    private let lock = NSLock()
    private var closed = false
    /// Called exactly once, after the connection closes, with `self` as the argument.
    /// Invoked outside the lock to avoid re-entrancy / deadlock.
    var onClose: (@Sendable (_ conn: ProxyConnection) -> Void)?

    init(tcp: FileHandle, guest: FileHandle) { self.tcp = tcp; self.guest = guest }

    func start() {
        pump(from: tcp, to: guest)
        pump(from: guest, to: tcp)
    }

    private func pump(from: FileHandle, to: FileHandle) {
        from.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { self?.close(); return }
            try? to.write(contentsOf: data)
        }
    }

    func close() {
        // Capture whether this call is the one that transitions to closed.
        // Release the lock before invoking onClose to avoid re-entrancy / deadlock.
        let shouldNotify: Bool
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
        shouldNotify = true
        lock.unlock()

        if shouldNotify { onClose?(self) }
    }
}
