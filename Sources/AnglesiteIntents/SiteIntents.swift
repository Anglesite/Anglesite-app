import AppIntents
import AnglesiteCore

/// The four App Intents. Each is a thin adapter over `SiteOperations` (Core), which holds all
/// the testable Result→dialog logic. No Claude/LLM process is involved — the intents drive the
/// deterministic command actors directly.

// `LongRunningIntent` (→ `ProgressReportingIntent` → `AppIntent`) tells the system this work
// can exceed the default intent execution budget, so a real deploy/audit invoked from Siri or
// a background Shortcut isn't killed mid-run. `CancellableIntent` lets the system offer a Cancel
// affordance; cancellation propagates into the operation task, whose command actor SIGTERMs the
// running build/wrangler so it actually stops (see DeployCommand/AuditCommand).
public struct DeploySiteIntent: LongRunningIntent, CancellableIntent {
    public static var title: LocalizedStringResource = "Deploy Site"
    public static var description = IntentDescription("Deploy a site to production with Anglesite.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Dependency private var ops: any SiteOperationsService

    public init() {}

    public static var parameterSummary: some ParameterSummary { Summary("Deploy \(\.$site)") }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        // Deploy is outward-facing (pushes to production), so confirm before running. The
        // pre-deploy security scan still gates inside DeployCommand — confirmation is an
        // additional guard against accidental voice/Shortcut triggers, not a replacement.
        try await requestConfirmation(
            dialog: "Deploy \(site.displayName) to production?"
        )
        guard let resolved = await ops.site(id: site.id) else {
            return .result(dialog: "Couldn't find \(site.displayName).")
        }
        // Deploys (build + wrangler) routinely exceed the default budget — run as long-running,
        // cancellable work. On cancel the operation task is cancelled, which terminates the
        // subprocess inside DeployCommand; `onCancel` is the system's acknowledgement hook.
        let result = try await performBackgroundTask {
            await ops.deploy(site: resolved)
        } onCancel: { _ in }
        return .result(dialog: IntentDialog(stringLiteral: SiteOperations.dialog(forDeploy: result)))
    }
}

public struct BackupSiteIntent: AppIntent {
    public static var title: LocalizedStringResource = "Back Up Site"
    public static var description = IntentDescription("Commit and push a site backup with Anglesite.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Dependency private var ops: any SiteOperationsService

    public init() {}

    public static var parameterSummary: some ParameterSummary { Summary("Back up \(\.$site)") }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let resolved = await ops.site(id: site.id) else {
            return .result(dialog: "Couldn't find \(site.displayName).")
        }
        let result = await ops.backup(site: resolved)
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
        guard let resolved = await ops.site(id: site.id) else {
            return .result(value: site, dialog: "Couldn't find \(site.displayName).")
        }
        // A full audit runs a site build + runners — can exceed the default budget. Cancellable:
        // on cancel the build subprocess is terminated inside AuditCommand.
        let result = try await performBackgroundTask {
            await ops.audit(site: resolved)
        } onCancel: { _ in }
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
