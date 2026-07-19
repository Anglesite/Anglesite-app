import Foundation

/// Resolves a site, runs a command inside `SiteAccess`, and provides user-facing dialog
/// strings. The App Intent structs are thin adapters over this; this type is fully
/// unit-testable with a fake `CommandFactory`.
///
/// A missing security-scoped grant (MAS) or a not-found site is mapped onto each command's
/// own `.failed` case so callers handle exactly one Result type per operation.
public struct SiteOperations: Sendable {
    typealias SocialWorkerAccess = @Sendable (
        _ site: SiteStore.Site,
        _ store: SiteStore,
        _ body: @Sendable @escaping (URL) async -> SocialWorkerProvisionCommand.Result
    ) async throws -> SocialWorkerProvisionCommand.Result

    private let factory: CommandFactory
    private let store: SiteStore
    private let socialWorkerAccess: SocialWorkerAccess

    public init(factory: CommandFactory = LiveCommandFactory(), store: SiteStore = .shared) {
        self.init(
            factory: factory,
            store: store,
            socialWorkerAccess: { site, store, body in
                try await SiteAccess.withScopedAccess(to: site, in: store, body)
            }
        )
    }

    init(factory: CommandFactory, store: SiteStore, socialWorkerAccess: @escaping SocialWorkerAccess) {
        self.factory = factory
        self.store = store
        self.socialWorkerAccess = socialWorkerAccess
    }

    /// Resolve a site id (as carried by `SiteEntity`) to the registry's `Site`.
    public func site(id: String) async -> SiteStore.Site? {
        await store.find(id: id)
    }

    // MARK: Operations

    public func deploy(site: SiteStore.Site, onProgress: ProgressHandler? = nil) async -> DeployCommand.Result {
        do {
            return try await SiteAccess.withScopedAccess(to: site, in: store) { url in
                await self.deployWithWorkerComposition(site: site, siteDirectory: url, onProgress: onProgress)
            }
        } catch let SiteAccess.AccessError.noGrant(message) {
            return .failed(reason: message, exitCode: nil)
        } catch {
            return .failed(reason: error.localizedDescription, exitCode: nil)
        }
    }

    /// Headless-deploy counterpart to `DeployModel.runDeploy`'s worker-composition wiring
    /// (#709 design §5/§8): computes the effective active worker set — settings-activated only,
    /// since this path (App Intents/Shortcuts) has no populated `SiteContentGraph` to derive
    /// component-tied activation from — and routes through `SocialWorkerProvisionCommand.provision`
    /// the same way the main Deploy button does, persisting the result on success.
    ///
    /// `onProgress` fidelity note: `SocialWorkerProvisionCommand.provision` has no milestone hook
    /// of its own (unlike `DeployCommand.deploy`, it's never been wired for one — it had no live
    /// caller before #709), so this emits the same coarse `OperationProgress.deployBuilding` /
    /// `.deployDeploying` milestones `DeployCommand.deploy` would have emitted around the
    /// build/deploy boundary, rather than `DeployCommand`'s finer per-step ones (preflight,
    /// finalizing). `SiteIntents.swift:59` is this path's one real consumer (Siri/Shortcuts
    /// progress) — dropping progress reporting to nothing would regress it; this keeps it coarser
    /// but non-silent without adding an `onProgress` parameter to `SocialWorkerProvisionCommand`
    /// itself, which would ripple into Tasks 3/4's signature and every other call site.
    private func deployWithWorkerComposition(
        site: SiteStore.Site, siteDirectory: URL, onProgress: ProgressHandler?
    ) async -> DeployCommand.Result {
        let configStore = SiteConfigStore(configDirectory: site.configDirectory)
        let settings = (try? await configStore.load()) ?? SiteSettings()
        let effectiveActiveIDs = WorkerActivation.effectiveActiveIDs(settings: settings, catalog: [], graph: nil)
        let features = WorkerActivation.mapToFeatures(effectiveActiveIDs)

        // Dynamic-route claims (#746): this path has no catalog fetcher wired (matching the
        // `catalog: []` activation choice above), but the on-disk cache from a previous GUI fetch
        // still lets active workers keep their `run_worker_first` routes — otherwise a headless
        // deploy would silently regenerate wrangler.toml without them. Validation failures refuse
        // the deploy before any Cloudflare call, mirroring `DeployModel.runDeploy`.
        let routeClaims: [WorkerRouteClaims.OwnedClaim]
        do {
            routeClaims = try WorkerRouteClaims.activeClaims(
                catalog: WorkerCatalogFetcher.cachedCatalog(), activeIDs: effectiveActiveIDs)
        } catch {
            return .failed(reason: "worker route claims are invalid: \(error)", exitCode: nil)
        }

        // Prefer the site's already-established Worker name (`.site-config`'s `CF_PROJECT_NAME`,
        // set at the first successful deploy or by a worker-name-conflict rename, #740) over
        // re-deriving one from the site's display name — mirrors `DeployModel.runDeploy`'s
        // resolution so the headless path can't silently revert a rename on every deploy.
        let existingConfig = (try? WebsiteAnalyticsAsset.loadConfig(siteDirectory: siteDirectory)) ?? ""
        let workerSiteName = SiteConfigFile.value(forKey: "CF_PROJECT_NAME", in: existingConfig)
            ?? SiteSlug.derive(from: site.name)

        onProgress?(.deployBuilding)
        onProgress?(.deployDeploying)
        let provisionResult = await factory.socialWorkerProvision().provision(
            siteID: site.id,
            siteDirectory: siteDirectory,
            siteName: workerSiteName,
            features: features,
            routeClaims: routeClaims.map(\.claim),
            knownResources: settings.provisionedWorkerResources ?? .init()
        )
        onProgress?(.deployFinalizing)

        if case .succeeded(_, let resources, _) = provisionResult {
            var updated = settings
            updated.lastDeployedWorkerIDs = Array(effectiveActiveIDs).sorted()
            updated.provisionedWorkerResources = resources
            try? await configStore.save(updated)
        }

        return provisionResult.asDeployCommandResult
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

    public func provisionSocialWorker(site: SiteStore.Site) async -> SocialWorkerProvisionCommand.Result {
        do {
            return try await socialWorkerAccess(site, store) { url in
                await factory.socialWorkerProvision().provision(
                    siteID: site.id,
                    siteDirectory: url,
                    siteName: SiteSlug.derive(from: site.name)
                )
            }
        } catch let SiteAccess.AccessError.noGrant(message) {
            return .failed(reason: message, exitCode: nil, resources: .init())
        } catch {
            return .failed(reason: error.localizedDescription, exitCode: nil, resources: .init())
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
        case .workerNameConflict(let name):
            return "Deploy blocked: the Worker name \"\(name)\" is already in use on your Cloudflare account. Rename the site's Worker in Anglesite and try again."
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

    public static func dialog(forSocialWorkerProvision result: SocialWorkerProvisionCommand.Result) -> String {
        switch result {
        case .succeeded(let url, let resources, _):
            return "Social Worker provisioned at \(url.absoluteString).\(resourceSuffix(resources))"
        case .blocked(let failures, _, let resources):
            let count = failures.count
            let noun = count == 1 ? "issue" : "issues"
            return "Social Worker provisioning blocked by the pre-deploy security scan (\(count) \(noun)).\(resourceSuffix(resources))"
        case .workerNameConflict(let name, let resources):
            return "Social Worker provisioning blocked: the Worker name \"\(name)\" is already in use on your Cloudflare account. Rename the site's Worker in Anglesite and try again.\(resourceSuffix(resources))"
        case .failed(let reason, _, let resources):
            return "Social Worker provisioning failed: \(reason).\(resourceSuffix(resources))"
        }
    }

    /// Friendly dialog for a Siri/Shortcuts cancellation, mapped from `Task.isCancelled` at the
    /// intent boundary (the command actor SIGTERMs the underlying subprocess on cancel).
    public static func canceledDialog(operation: String, siteName: String) -> String {
        "Canceled the \(operation) of \(siteName)."
    }

    private static func resourceSuffix(_ resources: WorkerComposition.ProvisionedResources) -> String {
        var labels: [String] = []
        if resources.d1DatabaseID != nil { labels.append("D1") }
        if resources.kvNamespaceID != nil { labels.append("KV") }
        if resources.r2BucketName != nil { labels.append("R2") }
        guard !labels.isEmpty else { return "" }
        return " Provisioned resources: \(labels.joined(separator: ", "))."
    }
}
