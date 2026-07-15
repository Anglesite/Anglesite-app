import Containerization
import ContainerizationExtras
import Foundation
import Testing
@testable import AnglesiteContainer
import AnglesiteCore

struct SharedVmnetNetworkTests {
    @Test("concurrent site allocations share one serialized network and release for reuse")
    func sharesNetworkAndReleasesInterfaces() async throws {
        let recorder = FakeNetworkRecorder()
        let allocator = SharedVmnetNetwork {
            recorder.recordFactoryCall()
            return FakeNetwork(recorder: recorder)
        }

        async let first = allocator.allocate(siteID: "first")
        async let second = allocator.allocate(siteID: "second")
        let (firstAllocation, secondAllocation) = try await (first, second)

        #expect(recorder.factoryCallCount == 1)
        #expect(firstAllocation.nameserver == "10.0.0.1")
        #expect(secondAllocation.nameserver == "10.0.0.1")
        #expect(firstAllocation.interface.ipv4Address != secondAllocation.interface.ipv4Address)
        #expect(recorder.activeSiteIDs == ["first", "second"])

        await allocator.release(siteID: "first")
        _ = try await allocator.allocate(siteID: "first")

        #expect(recorder.factoryCallCount == 1)
        #expect(recorder.releaseCalls == ["first"])
        #expect(recorder.activeSiteIDs == ["first", "second"])
    }

    @Test("an unusable allocation is released before the error escapes")
    func missingGatewayReleasesAllocation() async {
        let recorder = FakeNetworkRecorder(gateway: nil)
        let allocator = SharedVmnetNetwork { FakeNetwork(recorder: recorder) }

        await #expect(throws: LocalContainerError.bootFailed("vmnet did not allocate an IPv4 gateway")) {
            _ = try await allocator.allocate(siteID: "missing-gateway")
        }
        #expect(recorder.releaseCalls == ["missing-gateway"])
        #expect(recorder.activeSiteIDs.isEmpty)
    }
}

private struct FakeNetwork: Network {
    let recorder: FakeNetworkRecorder

    mutating func createInterface(_ id: String) throws -> (any Containerization.Interface)? {
        let host = try recorder.allocate(id)
        return NATInterface(
            ipv4Address: try CIDRv4("10.0.0.\(host)/24"),
            ipv4Gateway: recorder.gateway
        )
    }

    mutating func releaseInterface(_ id: String) throws {
        recorder.release(id)
    }
}

private final class FakeNetworkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let configuredGateway: IPv4Address?
    private var factoryCalls = 0
    private var nextHost = 2
    private var active: Set<String> = []
    private var releases: [String] = []

    init(gateway: IPv4Address? = try? IPv4Address("10.0.0.1")) {
        self.configuredGateway = gateway
    }

    var gateway: IPv4Address? { configuredGateway }
    var factoryCallCount: Int { lock.withLock { factoryCalls } }
    var activeSiteIDs: Set<String> { lock.withLock { active } }
    var releaseCalls: [String] { lock.withLock { releases } }

    func recordFactoryCall() {
        lock.withLock { factoryCalls += 1 }
    }

    func allocate(_ id: String) throws -> Int {
        try lock.withLock {
            guard active.insert(id).inserted else { throw FakeNetworkError.duplicate(id) }
            defer { nextHost += 1 }
            return nextHost
        }
    }

    func release(_ id: String) {
        lock.withLock {
            if active.remove(id) != nil { releases.append(id) }
        }
    }
}

private enum FakeNetworkError: Error {
    case duplicate(String)
}
