import AppIntents
import AnglesiteIntents  // for DeploySiteIntent, BackupSiteIntent, AuditSiteIntent (move-pending)

/// Curated Siri phrases. They appear in Spotlight and Siri suggestions. `\(.applicationName)`
/// resolves to the app's display name ("Anglesite") on both targets.
///
/// The audit→deploy chain is composed in the Shortcuts editor: `AuditSiteIntent` returns a
/// `SiteEntity` value that the user pipes into `DeploySiteIntent`, whose confirmation still
/// gates the deploy. No extra `opensIntent` plumbing is needed for v0.
struct AnglesiteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DeploySiteIntent(),
            phrases: ["Deploy my site with \(.applicationName)"],
            shortTitle: "Deploy Site",
            systemImageName: "arrow.up.circle"
        )
        AppShortcut(
            intent: BackupSiteIntent(),
            phrases: ["Back up my site with \(.applicationName)"],
            shortTitle: "Back Up Site",
            systemImageName: "externaldrive.badge.timemachine"
        )
        AppShortcut(
            intent: AuditSiteIntent(),
            phrases: ["Check my site with \(.applicationName)"],
            shortTitle: "Check Site",
            systemImageName: "checkmark.seal"
        )
    }
}
