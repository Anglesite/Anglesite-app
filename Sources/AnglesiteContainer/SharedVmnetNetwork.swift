import AnglesiteCore
import Containerization

/// The interface and DNS values allocated together from one vmnet network.
struct VmnetNetworkAllocation: Sendable {
    let interface: any Containerization.Interface
    let nameserver: String
}

/// One process-wide vmnet network with actor-serialized interface allocation.
///
/// `VmnetNetwork` owns both the `vmnet_network_ref` and its address allocator. Constructing one
/// per boot would consume a shared-mode network per site and discard the only value that can call
/// `releaseInterface`. Keeping one instance here mirrors upstream Containerization's manager/CLI
/// lifecycle, prevents concurrent site boots from racing network creation, and makes every site
/// allocation explicitly releasable on teardown (#715).
actor SharedVmnetNetwork {
    typealias NetworkFactory = @Sendable () throws -> any Network

    static let shared = SharedVmnetNetwork()

    private let makeNetwork: NetworkFactory
    private var network: (any Network)?

    init(makeNetwork: @escaping NetworkFactory = { try VmnetNetwork() }) {
        self.makeNetwork = makeNetwork
    }

    func allocate(siteID: String) throws -> VmnetNetworkAllocation {
        var network = try self.network ?? makeNetwork()

        do {
            guard let interface = try network.createInterface(siteID) else {
                self.network = network
                throw LocalContainerError.bootFailed("vmnet did not allocate an IPv4 interface")
            }
            guard let gateway = interface.ipv4Gateway else {
                try? network.releaseInterface(siteID)
                self.network = network
                throw LocalContainerError.bootFailed("vmnet did not allocate an IPv4 gateway")
            }

            self.network = network
            return VmnetNetworkAllocation(interface: interface, nameserver: gateway.description)
        } catch {
            // `Network` has mutating allocation methods, so persist its state even when an
            // implementation throws after partially handling a request.
            self.network = network
            throw error
        }
    }

    /// Best-effort and idempotent, matching the rest of container teardown.
    func release(siteID: String) {
        guard var network else { return }
        try? network.releaseInterface(siteID)
        self.network = network
    }
}
