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

    private func connectTCP(to url: URL) throws -> FileHandle {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
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

    @Test("client→guest: bytes written to the TCP client appear on the guest handle")
    func clientToGuest() async throws {
        let (guestForProxy, guestPeer) = socketPair()
        let proxy = VsockTCPProxy(guestPort: 4321, dial: { _ in guestForProxy })
        let url = try await proxy.start()
        let client = try connectTCP(to: url)
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
        let client = try connectTCP(to: url)
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
        let proxy = VsockTCPProxy(guestPort: 4321, dial: { _ in guestForProxy })
        let url = try await proxy.start()
        let client = try connectTCP(to: url)

        // Write a byte so the accept + dial path completes before we check the count.
        try client.write(contentsOf: Data("ping".utf8))
        _ = try guestPeer.read(upToCount: 4)

        // The connection should have been accepted and added.
        var count = await proxy.connectionCount
        #expect(count == 1)

        // Close the guest peer — the proxy's readabilityHandler sees EOF and calls close(),
        // which fires onClose → removeConnection via an async Task.
        try guestPeer.close()
        // Give the Task time to run on the actor.
        try await Task.sleep(for: .milliseconds(200))

        count = await proxy.connectionCount
        #expect(count == 0)

        await proxy.stop()
    }
}
