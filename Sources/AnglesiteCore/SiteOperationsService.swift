import Foundation

/// Seam for App Intents (and any future system entry point — system MCP per #101)
/// to call site operations without binding to the concrete `SiteOperations` type.
///
/// `SiteOperations` is the production conformance. Tests register a fake conforming type
/// with `AppDependencyManager.shared` to drive intent suites; see the AnglesiteIntents
/// test target.
public protocol SiteOperationsService: Sendable {
    func site(id: String) async -> SiteStore.Site?
    func deploy(site: SiteStore.Site) async -> DeployCommand.Result
    func backup(site: SiteStore.Site) async -> BackupCommand.Result
    func audit(site: SiteStore.Site) async -> AuditCommand.Result
}

extension SiteOperations: SiteOperationsService {}
