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
        // Set SO_RCVTIMEO so a splice failure fails the test instead of hanging CI.
        var tv = timeval(tv_sec: 2, tv_usec: 0)
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

    /// Set SO_RCVTIMEO on an existing file descriptor (e.g. the guest socketpair peer) so a
    /// splice failure fails the test instead of hanging CI.
    private func setRecvTimeout(_ fh: FileHandle, seconds: Int = 2) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fh.fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Poll `proxy.connectionCount` until it equals `n` or the timeout elapses, then return the
    /// final count. Replaces a fixed `Task.sleep` to avoid flaky CI timing.
    private func waitUntilConnectionCount(_ proxy: VsockTCPProxy, _ n: Int, timeout: Duration = .seconds(2)) async -> Int {
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
        // Read 5 bytes from the guest peer.
        let got = try guestPeer.read(upToCount: 5)
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
        let got = try client.read(upToCount: 5)
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

    @Test("closed connection is removed from connections (no unbounded growth)")
    func closedConnectionRemovedFromConnections() async throws {
        let (guestForProxy, guestPeer) = socketPair()
        setRecvTimeout(guestPeer)
        let proxy = VsockTCPProxy(guestPort: 4321, dial: { _ in guestForProxy })
        let url = try await proxy.start()
        let client = try connectTCPToProxy(to: url)

        // Write a byte so the accept + dial path completes before we check the count.
        try client.write(contentsOf: Data("ping".utf8))
        _ = try guestPeer.read(upToCount: 4)

        // The connection should have been accepted and added.
        let countAfterConnect = await waitUntilConnectionCount(proxy, 1)
        #expect(countAfterConnect == 1)

        // Close the guest peer — the proxy's readabilityHandler sees EOF and calls close(),
        // which fires onClose → removeConnection via an async Task.
        try guestPeer.close()

        // Poll with timeout instead of a fixed sleep: waits up to 2 s for the actor to process
        // the onClose Task, then asserts.
        let countAfterClose = await waitUntilConnectionCount(proxy, 0)
        #expect(countAfterClose == 0)

        await proxy.stop()
    }
}
