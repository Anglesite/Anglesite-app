import Testing
import Foundation
@testable import AnglesiteCore

struct VsockTCPProxyTests {
    /// Make a connected pair of FileHandles via socketpair(2). One end is handed to the proxy as
    /// the "guest"; the test holds the other to act as the guest peer.
    private func socketPair() -> (FileHandle, FileHandle) {
        var fds: [Int32] = [0, 0]
        let rc = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        #expect(rc == 0)
        return (FileHandle(fileDescriptor: fds[0], closeOnDealloc: true),
                FileHandle(fileDescriptor: fds[1], closeOnDealloc: true))
    }

    /// Connect a TCP client to the proxy's bound URL and return a FileHandle. Named to avoid
    /// shadowing POSIX `connect(2)`.
    private func connectTCPToProxy(to url: URL) throws -> FileHandle {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        // Per-read backstop so reads return (EAGAIN) for readExactly to poll; not the deadline.
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(url.port!)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(rc == 0)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Set SO_RCVTIMEO on an existing file descriptor (e.g. the guest socketpair peer) so each
    /// `read` syscall returns (with EAGAIN) rather than blocking forever — this is what lets
    /// `readExactly` poll. It is a per-read backstop, NOT the overall deadline.
    private func setRecvTimeout(_ fh: FileHandle, seconds: Int = 1) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fh.fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Read exactly `count` bytes from `fh`, accumulating across reads until the deadline. The
    /// proxy's splice pipeline is event-driven (DispatchSource accept → actor hop → readability
    /// handler) and can lag well past a second under heavy *parallel* test load on a small CI
    /// runner, so a single timed `read` races the pipeline and fails spuriously (errno 35 / EAGAIN).
    /// Polling against a generous deadline never fails on scheduling jitter, yet still bounds a
    /// genuinely-stuck splice instead of hanging CI forever. Requires SO_RCVTIMEO on `fh` so each
    /// `read` returns promptly to let the loop spin.
    private func readExactly(_ count: Int, from fh: FileHandle, timeout: Duration = .seconds(10)) async -> Data {
        let deadline = ContinuousClock.now + timeout
        var acc = Data()
        while acc.count < count && ContinuousClock.now < deadline {
            if let chunk = try? fh.read(upToCount: count - acc.count), !chunk.isEmpty {
                acc.append(chunk)
            } else {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        return acc
    }

    /// Poll `proxy.connectionCount` until it equals `n` or the timeout elapses, then return the
    /// final count. Replaces a fixed `Task.sleep` to avoid flaky CI timing.
    private func waitUntilConnectionCount(_ proxy: VsockTCPProxy, _ n: Int, timeout: Duration = .seconds(10)) async -> Int {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let count = await proxy.connectionCount
            if count == n { return count }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await proxy.connectionCount
    }

    @Test("client→guest: bytes written to the TCP client appear on the guest handle")
    func clientToGuest() async throws {
        let (guestForProxy, guestPeer) = socketPair()
        setRecvTimeout(guestPeer)
        let proxy = VsockTCPProxy(guestPort: 4321, dial: { _ in guestForProxy })
        let url = try await proxy.start()
        let client = try connectTCPToProxy(to: url)
        try client.write(contentsOf: Data("hello".utf8))
        // Read 5 bytes from the guest peer (poll the event-driven splice; see readExactly).
        let got = await readExactly(5, from: guestPeer)
        #expect(got == Data("hello".utf8))
        await proxy.stop()
    }

    @Test("guest→client: bytes written to the guest handle appear at the TCP client")
    func guestToClient() async throws {
        let (guestForProxy, guestPeer) = socketPair()
        let proxy = VsockTCPProxy(guestPort: 4321, dial: { _ in guestForProxy })
        let url = try await proxy.start()
        let client = try connectTCPToProxy(to: url)
        setRecvTimeout(client)
        try guestPeer.write(contentsOf: Data("world".utf8))
        let got = await readExactly(5, from: client)
        #expect(got == Data("world".utf8))
        await proxy.stop()
    }

    @Test("start returns a loopback URL with a nonzero OS-assigned port")
    func assignsPort() async throws {
        let (guestForProxy, _) = socketPair()
        let proxy = VsockTCPProxy(guestPort: 4321, dial: { _ in guestForProxy })
        let url = try await proxy.start()
        #expect(url.host == "127.0.0.1")
        #expect((url.port ?? 0) > 0)
        await proxy.stop()
    }

    /// Regression test for #69: `waitUntilServing` polls the proxy's URL with a fresh short-lived
    /// TCP connection roughly every 500ms until the guest answers. Each poll dials a fresh guest
    /// pair and is abruptly abandoned client-side (mirroring `URLSession` giving up on a slow/no
    /// response and opening a new connection next tick) — the proxy must keep serving unrelated,
    /// later connections cleanly rather than getting wedged after the churn. This does not
    /// reproduce the exact `FileHandle`-accessor race the raw-POSIX rewrite fixes (that race is
    /// timing-dependent and only surfaced on a real device — see #69/#470), but it does guard the
    /// observable symptom: repeated connect/abandon cycles must not corrupt state for later, real
    /// connections.
    @Test("proxy keeps serving new connections after many abrupt client-side disconnects")
    func survivesRepeatedAbruptDisconnects() async throws {
        for _ in 0..<20 {
            let (guestForProxy, guestPeer) = socketPair()
            let proxy = VsockTCPProxy(guestPort: 4321, dial: { _ in guestForProxy })
            let url = try await proxy.start()
            let client = try connectTCPToProxy(to: url)
            // Abandon immediately — no write, no read — the same shape as a client that opens a
            // socket, gets no prompt response, and gives up before the next poll tick.
            try client.close()
            await proxy.stop()
            try? guestPeer.close()
        }

        // One more, real, iteration: the proxy must still relay correctly after the churn above.
        let (guestForProxy, guestPeer) = socketPair()
        setRecvTimeout(guestPeer)
        let proxy = VsockTCPProxy(guestPort: 4321, dial: { _ in guestForProxy })
        let url = try await proxy.start()
        let client = try connectTCPToProxy(to: url)
        try client.write(contentsOf: Data("hello".utf8))
        let got = await readExactly(5, from: guestPeer)
        #expect(got == Data("hello".utf8))
        await proxy.stop()
    }

    /// Regression test for #69: a failing `dial(guestPort)` (e.g. `container.dialVsock` unable to
    /// reach the guest) was previously swallowed by `handleAccepted`'s `catch { try? tcp.close() }`
    /// with zero diagnostic trail — indistinguishable from a slow/hung guest process. The client
    /// just saw its TCP connection close with no data, which is exactly `NSURLErrorNetworkConnection
    /// Lost` on the `URLSession` side. `onDialError` surfaces the real underlying error instead.
    @Test("a failing dial() reports the error via onDialError instead of failing silently")
    func dialFailureReportsError() async throws {
        struct DialError: Error, Equatable { let message: String }
        let collector = LineCollector()
        let proxy = VsockTCPProxy(
            guestPort: 4321,
            dial: { _ in throw DialError(message: "boom") },
            onDialError: { error in collector.append("\(error)", .stderr) })
        let url = try await proxy.start()
        let client = try connectTCPToProxy(to: url)
        setRecvTimeout(client)

        // The client's connection should be closed (no bytes ever sent) once the dial fails.
        let got = await readExactly(1, from: client, timeout: .seconds(5))
        #expect(got.isEmpty)

        // The dial failure must have been reported, not swallowed.
        #expect(collector.lines.contains { $0.contains("boom") })
        await proxy.stop()
    }

    @Test("closed connection is removed from connections (no unbounded growth)")
    func closedConnectionRemovedFromConnections() async throws {
        let (guestForProxy, guestPeer) = socketPair()
        setRecvTimeout(guestPeer)
        let proxy = VsockTCPProxy(guestPort: 4321, dial: { _ in guestForProxy })
        let url = try await proxy.start()
        let client = try connectTCPToProxy(to: url)

        // Write a byte so the accept + dial path completes before we check the count.
        try client.write(contentsOf: Data("ping".utf8))
        _ = await readExactly(4, from: guestPeer)

        // The connection should have been accepted and added.
        let countAfterConnect = await waitUntilConnectionCount(proxy, 1)
        #expect(countAfterConnect == 1)

        // Close the guest peer — the proxy's readabilityHandler sees EOF and calls close(),
        // which fires onClose → removeConnection via an async Task.
        try guestPeer.close()

        // Poll with timeout instead of a fixed sleep: waits up to the deadline for the actor to
        // process the onClose Task, then asserts.
        let countAfterClose = await waitUntilConnectionCount(proxy, 0)
        #expect(countAfterClose == 0)

        await proxy.stop()
    }
}
