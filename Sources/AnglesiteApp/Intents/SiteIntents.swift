import AppIntents
import AnglesiteCore

/// The four App Intents. Each is a thin adapter over `SiteOperations` (Core), which holds all
/// the testable Result→dialog logic. No Claude/LLM process is involved — the intents drive the
/// deterministic command actors directly.

struct DeploySiteIntent: AppIntent {
    static var title: LocalizedStringResource = "Deploy Site"
    static var description = IntentDescription("Deploy a site to production with Anglesite.")

    @Parameter(title: "Site") var site: SiteEntity

    static var parameterSummary: some ParameterSummary { Summary("Deploy \(\.$site)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Deploy is outward-facing (pushes to production), so confirm before running. The
        // pre-deploy security scan still gates inside DeployCommand — confirmation is an
        // additional guard against accidental voice/Shortcut triggers, not a replacement.
        try await requestConfirmation(
            result: .result(dialog: "Deploy \(site.displayName) to production?")
        )
        let ops = SiteOperations()
        guard let resolved = await ops.site(id: site.id) else {
            return .result(dialog: "Couldn't find \(site.displayName).")
        }
        let result = await ops.deploy(site: resolved)
        return .result(dialog: IntentDialog(stringLiteral: SiteOperations.dialog(forDeploy: result)))
    }
}

struct BackupSiteIntent: AppIntent {
    static var title: LocalizedStringResource = "Back Up Site"
    static var description = IntentDescription("Commit and push a site backup with Anglesite.")

    @Parameter(title: "Site") var site: SiteEntity

    static var parameterSummary: some ParameterSummary { Summary("Back up \(\.$site)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ops = SiteOperations()
        guard let resolved = await ops.site(id: site.id) else {
            return .result(dialog: "Couldn't find \(site.displayName).")
        }
        let result = await ops.backup(site: resolved)
        return .result(dialog: IntentDialog(stringLiteral: SiteOperations.dialog(forBackup: result)))
    }
}

struct AuditSiteIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Site"
    static var description = IntentDescription("Run an Anglesite audit and report findings.")

    @Parameter(title: "Site") var site: SiteEntity

    static var parameterSummary: some ParameterSummary { Summary("Check \(\.$site)") }

    // Returns the site as a value so a Shortcut can pipe it straight into Deploy (audit→deploy).
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<SiteEntity> {
        let ops = SiteOperations()
        guard let resolved = await ops.site(id: site.id) else {
            return .result(value: site, dialog: "Couldn't find \(site.displayName).")
        }
        let result = await ops.audit(site: resolved)
        return .result(value: site, dialog: IntentDialog(stringLiteral: SiteOperations.dialog(forAudit: result)))
    }
}

struct OpenSiteIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Site"
    static var description = IntentDescription("Open a site window in Anglesite.")
    static var openAppWhenRun = true

    @Parameter(title: "Site") var site: SiteEntity

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$site)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        WindowRouter.shared.requestOpen(siteID: site.id)
        return .result(dialog: "Opening \(site.displayName).")
    }
}
