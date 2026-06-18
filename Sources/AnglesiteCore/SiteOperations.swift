import Foundation

/// Resolves a site, runs a command inside `SiteAccess`, and provides user-facing dialog
/// strings. The App Intent structs are thin adapters over this; this type is fully
/// unit-testable with a fake `CommandFactory`.
///
/// A missing security-scoped grant (MAS) or a not-found site is mapped onto each command's
/// own `.failed` case so callers handle exactly one Result type per operation.
public struct SiteOperations: Sendable {
    private let factory: CommandFactory
    private let store: SiteStore

    public init(factory: CommandFactory = LiveCommandFactory(), store: SiteStore = .shared) {
        self.factory = factory
        self.store = store
    }

    /// Resolve a site id (as carried by `SiteEntity`) to the registry's `Site`.
    public func site(id: String) async -> SiteStore.Site? {
        await store.find(id: id)
    }

    // MARK: Operations

    public func deploy(site: SiteStore.Site, onProgress: ProgressHandler? = nil) async -> DeployCommand.Result {
        do {
            return try await SiteAccess.withScopedAccess(to: site, in: store) { url in
                await factory.deploy().deploy(siteID: site.id, siteDirectory: url, onProgress: onProgress)
            }
        } catch let SiteAccess.AccessError.noGrant(message) {
            return .failed(reason: message, exitCode: nil)
        } catch {
            return .failed(reason: error.localizedDescription, exitCode: nil)
        }
    }

    public func backup(site: SiteStore.Site, onProgress: ProgressHandler? = nil) async -> BackupCommand.Result {
        do {
            return try await SiteAccess.withScopedAccess(to: site, in: store) { url in
                await factory.backup().backup(siteID: site.id, siteDirectory: url, onProgress: onProgress)
            }
        } catch let SiteAccess.AccessError.noGrant(message) {
            return .failed(reason: message, exitCode: nil)
        } catch {
            return .failed(reason: error.localizedDescription, exitCode: nil)
        }
    }

    public func audit(site: SiteStore.Site, onProgress: ProgressHandler? = nil) async -> AuditCommand.Result {
        do {
            return try await SiteAccess.withScopedAccess(to: site, in: store) { url in
                await factory.audit().audit(siteID: site.id, siteDirectory: url, onProgress: onProgress)
            }
        } catch let SiteAccess.AccessError.noGrant(message) {
            return .failed(reason: message, exitCode: nil, logTail: [])
        } catch {
            return .failed(reason: error.localizedDescription, exitCode: nil, logTail: [])
        }
    }

    // MARK: Dialog mapping (pure)

    public static func dialog(forDeploy result: DeployCommand.Result) -> String {
        switch result {
        case .succeeded(let url, _):
            return "Deployed to \(url.absoluteString)."
        case .blocked(let failures, _):
            let count = failures.count
            let noun = count == 1 ? "issue" : "issues"
            return "Deploy blocked by the pre-deploy security scan (\(count) \(noun)). Resolve these in Anglesite first."
        case .failed(let reason, _):
            return "Deploy failed: \(reason)"
        }
    }

    public static func dialog(forBackup result: BackupCommand.Result) -> String {
        switch result {
        case .succeeded(let sha, _, let remote):
            return "Backed up \(sha.prefix(7)) to \(remote)."
        case .noChanges:
            return "No changes to back up."
        case .failed(let reason, _):
            return "Backup failed: \(reason)"
        }
    }

    public static func dialog(forAudit result: AuditCommand.Result) -> String {
        switch result {
        case .succeeded(let report, _):
            let c = report.findings.filter { $0.severity == .critical }.count
            let w = report.findings.filter { $0.severity == .warning }.count
            let i = report.findings.filter { $0.severity == .info }.count
            return "Audit complete: \(c) critical, \(w) warning, \(i) info."
        case .failed(let reason, _, _):
            return "Audit failed: \(reason)"
        }
    }

    /// Friendly dialog for a Siri/Shortcuts cancellation, mapped from `Task.isCancelled` at the
    /// intent boundary (the command actor SIGTERMs the underlying subprocess on cancel).
    public static func canceledDialog(operation: String, siteName: String) -> String {
        "Canceled the \(operation) of \(siteName)."
    }
}
