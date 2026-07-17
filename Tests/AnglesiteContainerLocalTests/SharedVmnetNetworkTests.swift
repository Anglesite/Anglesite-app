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

    @Test("reset discards the cached network so the next allocate rebuilds it (#812)")
    func resetForcesRebuild() async throws {
        // Each factory call gets its own recorder — mirrors real `VmnetNetwork.init` building a
        // fresh, empty `Allocator` per instance, not one shared across every network this process
        // ever creates.
        let factory = RecordingFactory()
        let allocator = SharedVmnetNetwork {
            FakeNetwork(recorder: factory.makeRecorder())
        }

        _ = try await allocator.allocate(siteID: "before-reset")
        #expect(factory.callCount == 1)

        await allocator.reset()

        // A fresh network's allocator has no memory of the pre-reset siteID, so the same id can be
        // allocated again without the "already exists" error `FakeNetworkRecorder.allocate` throws
        // for a live duplicate against the SAME network instance.
        _ = try await allocator.allocate(siteID: "before-reset")
        #expect(factory.callCount == 2)
        #expect(factory.recorderCount == 2)
    }

    @Test("reset before any allocation is a harmless no-op")
    func resetWithoutPriorAllocation() async throws {
        let factory = RecordingFactory()
        let allocator = SharedVmnetNetwork {
            FakeNetwork(recorder: factory.makeRecorder())
        }

        await allocator.reset()
        _ = try await allocator.allocate(siteID: "first-ever")
        #expect(factory.callCount == 1)
    }
}

/// Hands out a fresh `FakeNetworkRecorder` per factory call while tracking how many were made —
/// mirrors `FakeNetworkRecorder`'s own locking style below. A plain captured `var` won't compile
/// here: `SharedVmnetNetwork.NetworkFactory` is `@Sendable`, so the factory closure can't mutate a
/// non-isolated local.
private final class RecordingFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var recorders: [FakeNetworkRecorder] = []

    var callCount: Int { lock.withLock { calls } }
    var recorderCount: Int { lock.withLock { recorders.count } }

    func makeRecorder() -> FakeNetworkRecorder {
        lock.withLock {
            calls += 1
            let recorder = FakeNetworkRecorder()
            recorders.append(recorder)
            return recorder
        }
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
