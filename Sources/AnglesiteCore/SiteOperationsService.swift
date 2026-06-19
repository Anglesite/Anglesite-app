import Foundation

/// Seam for App Intents (and any future system entry point — system MCP per #101)
/// to call site operations without binding to the concrete `SiteOperations` type.
///
/// `SiteOperations` is the production conformance. Tests register a fake conforming type
/// with `AppDependencyManager.shared` to drive intent suites; see the AnglesiteIntents
/// test target.
public protocol SiteOperationsService: Sendable {
    func site(id: String) async -> SiteStore.Site?
    func deploy(site: SiteStore.Site, onProgress: ProgressHandler?) async -> DeployCommand.Result
    func backup(site: SiteStore.Site, onProgress: ProgressHandler?) async -> BackupCommand.Result
    func audit(site: SiteStore.Site, onProgress: ProgressHandler?) async -> AuditCommand.Result
}

public extension SiteOperationsService {
    func deploy(site: SiteStore.Site) async -> DeployCommand.Result { await deploy(site: site, onProgress: nil) }
    func backup(site: SiteStore.Site) async -> BackupCommand.Result { await backup(site: site, onProgress: nil) }
    func audit(site: SiteStore.Site) async -> AuditCommand.Result { await audit(site: site, onProgress: nil) }
}

extension SiteOperations: SiteOperationsService {}
