import Foundation

/// Diffs the current published route set against the snapshot from the previous deploy
/// (`DeployedRoutesSnapshot`), flagging any route that vanished with no `redirects.json` entry
/// covering it. Pure `SiteContentGraph`/`RedirectsStore` diffing — no JS/plugin involvement,
/// unlike the rest of `PreDeployCheck`'s checks.
public enum RouteCoverageScanner {
    public static func scan(
        currentRoutes: [String],
        previousRoutes: [String]?,
        redirectSources: Set<String>
    ) -> [PreDeployCheck.ScanWarning] {
        guard let previousRoutes else { return [] }
        let current = Set(currentRoutes)
        let vanished = Set(previousRoutes).subtracting(current).subtracting(redirectSources)
        return vanished.sorted().map { route in
            PreDeployCheck.ScanWarning(
                category: .orphanedRoute,
                detail: "\(route) is no longer published and has no redirect covering it.",
                remediation: "Add a redirect for \(route) in Site Settings → Redirects, or ignore if the removal is intentional."
            )
        }
    }
}
