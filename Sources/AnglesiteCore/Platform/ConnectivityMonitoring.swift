import Foundation

/// Portable connectivity seam used by the local-first publish queue. A monitor reports the
/// initial state and subsequent transitions until `stop()`.
public protocol ConnectivityMonitoring: Sendable {
    func start(onChange: @escaping @Sendable (Bool) -> Void)
    func stop()
}

public enum PlatformConnectivityMonitor {
    public static func make() -> any ConnectivityMonitoring {
        #if canImport(Network)
        NWConnectivityMonitor()
        #else
        AssumedOnlineConnectivityMonitor()
        #endif
    }
}

/// Platforms without Network.framework still get deterministic foreground publishing. Their
/// native connectivity monitor is supplied by the cross-platform port rather than guessed here.
public final class AssumedOnlineConnectivityMonitor: ConnectivityMonitoring, @unchecked Sendable {
    public init() {}
    public func start(onChange: @escaping @Sendable (Bool) -> Void) { onChange(true) }
    public func stop() {}
}

#if canImport(Network)
import Network

public final class NWConnectivityMonitor: ConnectivityMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.dwk.anglesite.connectivity")
    private let lock = NSLock()
    private var running = false

    public init() {}

    public func start(onChange: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        monitor.pathUpdateHandler = { path in onChange(path.status == .satisfied) }
        monitor.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        lock.unlock()
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }
}
#endif
