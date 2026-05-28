import Foundation

/// XPC service entry point. `NSXPCListener.service()` returns the launchd-provided listener
/// for this process; everything else is wired up in `HelperListenerDelegate`.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: AnglesiteHelperProtocol.self)
        newConnection.remoteObjectInterface = NSXPCInterface(with: HelperClientProtocol.self)

        let service = HelperService(connection: newConnection)
        newConnection.exportedObject = service

        newConnection.invalidationHandler = { [weak service] in
            Task { await service?.connectionInvalidated() }
        }
        newConnection.interruptionHandler = { [weak service] in
            Task { await service?.connectionInvalidated() }
        }

        newConnection.resume()
        return true
    }
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
