import AppIntents
import AnglesiteCore

/// The four App Intents. Each is a thin adapter over `SiteOperations` (Core), which holds all
/// the testable Result→dialog logic. No Claude/LLM process is involved — the intents drive the
/// deterministic command actors directly.
///
/// Tests bypass `@Dependency` and `requestConfirmation` through `SiteOperationsOverride.scoped`.
/// `@Dependency` is gated by the AppIntents runtime to its own perform flow — direct
/// `intent.perform()` calls from unit tests would otherwise crash. See `SiteOperationsOverride`.
///
/// macOS 27 — `LongRunningIntent` / `CancellableIntent` / `performBackgroundTask(onCancel:)` —
/// are gated behind `#if compiler(>=6.4)` until GH ships Xcode 27 on the macos-15 runner. On
/// Xcode 26.3 (Swift 6.3) the intents fall back to plain `AppIntent` with inline `await` calls
/// (no extended budget, no Cancel UI). See #128 for cleanup once CI catches up.

public struct DeploySiteIntent: AppIntent {
    public static let title: LocalizedStringResource = "Deploy Site"
    public static let description = IntentDescription("Deploy a site to production with Anglesite.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Dependency private var ops: any SiteOperationsService

    public init() {}

    public static var parameterSummary: some ParameterSummary { Summary("Deploy \(\.$site)") }

    // Returns the site as a value (like AuditSiteIntent) so an agent/Shortcut can chain
    // deploy→backup or audit→deploy→backup. The MCP bridge surfaces this as a typed output.
    public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<SiteEntity> {
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
            return .result(value: site, dialog: "Couldn't find \(site.displayName).")
        }
        // Deploys (build + wrangler) routinely exceed the default budget. On Xcode 27 we run via
        // `performBackgroundTask(onCancel:)` so the system can offer Cancel and we get extended
        // execution time. On Xcode 26.3 those APIs don't exist; fall back to inline await — the
        // deploy will run but isn't cancellable from the system UI.
        let result: DeployCommand.Result
        if scoped != nil {
            result = await ops.deploy(site: resolved)
        } else {
            #if compiler(>=6.4)
            let onProgress = IntentProgressAdapter.handler(for: self.progress)
            result = try await performBackgroundTask {
                await ops.deploy(site: resolved, onProgress: onProgress)
            } onCancel: { _ in }
            #else
            result = await ops.deploy(site: resolved)
            #endif
        }
        if Task.isCancelled {
            return .result(value: site, dialog: IntentDialog(stringLiteral: SiteOperations.canceledDialog(operation: "deploy", siteName: site.displayName)))
        }
        return .result(value: site, dialog: IntentDialog(stringLiteral: SiteOperations.dialog(forDeploy: result)))
    }
}

public struct BackupSiteIntent: AppIntent {
    public static let title: LocalizedStringResource = "Back Up Site"
    public static let description = IntentDescription("Commit and push a site backup with Anglesite.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Dependency private var ops: any SiteOperationsService

    public init() {}

    public static var parameterSummary: some ParameterSummary { Summary("Back up \(\.$site)") }

    // Returns the site as a value (like Audit/Deploy) so an agent/Shortcut can chain backup
    // into a follow-up site operation. The MCP bridge surfaces this as a typed output.
    public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<SiteEntity> {
        let scoped = SiteOperationsOverride.scoped
        let ops = scoped ?? self.ops
        guard let resolved = await ops.site(id: site.id) else {
            return .result(value: site, dialog: "Couldn't find \(site.displayName).")
        }
        // git push on a slow connection or large repo can exceed the default budget. Same
        // long-running + cancellable adoption as deploy/audit on Xcode 27; fallback on 26.3.
        let result: BackupCommand.Result
        if scoped != nil {
            result = await ops.backup(site: resolved)
        } else {
            #if compiler(>=6.4)
            let onProgress = IntentProgressAdapter.handler(for: self.progress)
            result = try await performBackgroundTask {
                await ops.backup(site: resolved, onProgress: onProgress)
            } onCancel: { _ in }
            #else
            result = await ops.backup(site: resolved)
            #endif
        }
        if Task.isCancelled {
            return .result(value: site, dialog: IntentDialog(stringLiteral: SiteOperations.canceledDialog(operation: "backup", siteName: site.displayName)))
        }
        return .result(value: site, dialog: IntentDialog(stringLiteral: SiteOperations.dialog(forBackup: result)))
    }
}

public struct AuditSiteIntent: AppIntent {
    public static let title: LocalizedStringResource = "Check Site"
    public static let description = IntentDescription("Run an Anglesite audit and report findings.")

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
        // A full audit (build + runners) can exceed the default budget. Same long-running +
        // cancellable adoption as deploy/backup on Xcode 27; fallback on 26.3.
        let result: AuditCommand.Result
        if scoped != nil {
            result = await ops.audit(site: resolved)
        } else {
            #if compiler(>=6.4)
            let onProgress = IntentProgressAdapter.handler(for: self.progress)
            result = try await performBackgroundTask {
                await ops.audit(site: resolved, onProgress: onProgress)
            } onCancel: { _ in }
            #else
            result = await ops.audit(site: resolved)
            #endif
        }
        if Task.isCancelled {
            return .result(value: site, dialog: IntentDialog(stringLiteral: SiteOperations.canceledDialog(operation: "check", siteName: site.displayName)))
        }
        return .result(value: site, dialog: IntentDialog(stringLiteral: SiteOperations.dialog(forAudit: result)))
    }
}

/// `OpenIntent` (not just `AppIntent`) so Spotlight's semantic-index hits on `SiteEntity` know
/// which verb to run when the user clicks a result. The `OpenIntent` protocol requires the
/// entity parameter to be named `target` — that contract is also why Shortcuts can chain
/// "find a site" → "open that site" by piping the resolved entity straight in.
public struct OpenSiteIntent: OpenIntent {
    public static let title: LocalizedStringResource = "Open Site"
    public static let description = IntentDescription("Open a site window in Anglesite.")
    public static let openAppWhenRun = true

    @Parameter(title: "Site") public var target: SiteEntity

    public init() {}

    public static var parameterSummary: some ParameterSummary { Summary("Open \(\.$target)") }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        WindowRouter.shared.requestOpen(siteID: target.id)
        return .result(dialog: "Opening \(target.displayName).")
    }
}

// `LongRunningIntent` (→ `ProgressReportingIntent` → `AppIntent`) tells the system this work
// can exceed the default intent execution budget, so a real deploy/audit/backup invoked from
// Siri or a background Shortcut isn't killed mid-run. `CancellableIntent` lets the system
// offer a Cancel affordance; cancellation propagates into the operation task, whose command
// actor SIGTERMs the running build/wrangler/git so it actually stops (see DeployCommand,
// AuditCommand, BackupCommand). Both protocols are marker-only — no required methods —
// so empty conditional conformance extensions are sufficient. Gated until #128 lands.
#if compiler(>=6.4)
extension DeploySiteIntent: LongRunningIntent, CancellableIntent {}
extension BackupSiteIntent: LongRunningIntent, CancellableIntent {}
extension AuditSiteIntent: LongRunningIntent, CancellableIntent {}
#endif
