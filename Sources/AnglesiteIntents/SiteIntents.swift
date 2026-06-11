import AppIntents
import AnglesiteCore

/// The four App Intents. Each is a thin adapter over `SiteOperations` (Core), which holds all
/// the testable Result→dialog logic. No Claude/LLM process is involved — the intents drive the
/// deterministic command actors directly.
///
/// Tests bypass `@Dependency` and `requestConfirmation` through `SiteOperationsOverride.scoped`.
/// `@Dependency` is gated by the AppIntents runtime to its own perform flow — direct
/// `intent.perform()` calls from unit tests would otherwise crash. See `SiteOperationsOverride`.

// `LongRunningIntent` (→ `ProgressReportingIntent` → `AppIntent`) tells the system this work
// can exceed the default intent execution budget, so a real deploy/audit/backup invoked from
// Siri or a background Shortcut isn't killed mid-run. `CancellableIntent` lets the system
// offer a Cancel affordance; cancellation propagates into the operation task, whose command
// actor SIGTERMs the running build/wrangler/git so it actually stops (see DeployCommand,
// AuditCommand). Backup uses the same conformance because `git push` over a slow connection
// on a large repo can exceed the default budget too.
public struct DeploySiteIntent: LongRunningIntent, CancellableIntent {
    public static var title: LocalizedStringResource = "Deploy Site"
    public static var description = IntentDescription("Deploy a site to production with Anglesite.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Dependency private var ops: any SiteOperationsService

    public init() {}

    public static var parameterSummary: some ParameterSummary { Summary("Deploy \(\.$site)") }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let scoped = SiteOperationsOverride.scoped
        let ops: any SiteOperationsService
        if let scoped {
            // Test scope: skip the confirmation prompt (no UI surface) and bypass @Dependency.
            ops = scoped
        } else {
            // Deploy is outward-facing (pushes to production), so confirm before running. The
            // pre-deploy security scan still gates inside DeployCommand — confirmation is an
            // additional guard against accidental voice/Shortcut triggers, not a replacement.
            try await requestConfirmation(
                dialog: "Deploy \(site.displayName) to production?"
            )
            ops = self.ops
        }
        guard let resolved = await ops.site(id: site.id) else {
            return .result(dialog: "Couldn't find \(site.displayName).")
        }
        // Deploys (build + wrangler) routinely exceed the default budget — run as long-running,
        // cancellable work. On cancel the operation task is cancelled, which terminates the
        // subprocess inside DeployCommand; `onCancel` is the system's acknowledgement hook.
        // In test scope `performBackgroundTask` isn't available (no AppIntents runtime), so we
        // run the closure inline; cancellation isn't exercised under `swift test`.
        let result: DeployCommand.Result
        if scoped != nil {
            result = await ops.deploy(site: resolved)
        } else {
            result = try await performBackgroundTask {
                await ops.deploy(site: resolved)
            } onCancel: { _ in }
        }
        return .result(dialog: IntentDialog(stringLiteral: SiteOperations.dialog(forDeploy: result)))
    }
}

public struct BackupSiteIntent: LongRunningIntent, CancellableIntent {
    public static var title: LocalizedStringResource = "Back Up Site"
    public static var description = IntentDescription("Commit and push a site backup with Anglesite.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Dependency private var ops: any SiteOperationsService

    public init() {}

    public static var parameterSummary: some ParameterSummary { Summary("Back up \(\.$site)") }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let scoped = SiteOperationsOverride.scoped
        let ops = scoped ?? self.ops
        guard let resolved = await ops.site(id: site.id) else {
            return .result(dialog: "Couldn't find \(site.displayName).")
        }
        // Backups (commit + push) can run long on slow networks / large repos — long-running,
        // cancellable. On cancel the git subprocess is terminated inside BackupCommand.
        let result: BackupCommand.Result
        if scoped != nil {
            result = await ops.backup(site: resolved)
        } else {
            result = try await performBackgroundTask {
                await ops.backup(site: resolved)
            } onCancel: { _ in }
        }
        return .result(dialog: IntentDialog(stringLiteral: SiteOperations.dialog(forBackup: result)))
    }
}

public struct AuditSiteIntent: LongRunningIntent, CancellableIntent {
    public static var title: LocalizedStringResource = "Check Site"
    public static var description = IntentDescription("Run an Anglesite audit and report findings.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Dependency private var ops: any SiteOperationsService

    public init() {}

    public static var parameterSummary: some ParameterSummary { Summary("Check \(\.$site)") }

    // Returns the site as a value so a Shortcut can pipe it straight into Deploy (audit→deploy).
    public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<SiteEntity> {
        let scoped = SiteOperationsOverride.scoped
        let ops = scoped ?? self.ops
        guard let resolved = await ops.site(id: site.id) else {
            return .result(value: site, dialog: "Couldn't find \(site.displayName).")
        }
        // A full audit runs a site build + runners — can exceed the default budget. Cancellable:
        // on cancel the build subprocess is terminated inside AuditCommand.
        let result: AuditCommand.Result
        if scoped != nil {
            result = await ops.audit(site: resolved)
        } else {
            result = try await performBackgroundTask {
                await ops.audit(site: resolved)
            } onCancel: { _ in }
        }
        return .result(value: site, dialog: IntentDialog(stringLiteral: SiteOperations.dialog(forAudit: result)))
    }
}

public struct OpenSiteIntent: AppIntent {
    public static var title: LocalizedStringResource = "Open Site"
    public static var description = IntentDescription("Open a site window in Anglesite.")
    public static var openAppWhenRun = true

    @Parameter(title: "Site") public var site: SiteEntity

    public init() {}

    public static var parameterSummary: some ParameterSummary { Summary("Open \(\.$site)") }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        WindowRouter.shared.requestOpen(siteID: site.id)
        return .result(dialog: "Opening \(site.displayName).")
    }
}
