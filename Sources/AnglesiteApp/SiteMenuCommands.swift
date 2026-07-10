import SwiftUI
import AppKit

/// The Site menu: the focused site window's primary operations, mirroring the toolbar so every
/// action has a menu home and a keyboard path (#511). Reads the `\.siteWindowModel` focused scene
/// value (SaveCommands.swift); every item disables when no site window is focused. Enablement
/// mirrors the toolbar via the shared `canRun…` properties on `SiteWindowModel`.
struct SiteMenuCommands: Commands {
    @FocusedValue(\.siteWindowModel) private var model

    var body: some Commands {
        // SwiftUI inserts a CommandMenu between the View and Window menus — the standard spot
        // for an app-domain menu.
        CommandMenu("Site") {
            Button("Deploy") { model?.deploySite() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model?.canRunDeploy != true)

            Button("Recheck Deploy Readiness") { model?.recheckHealth() }
                .disabled(model?.canRecheckHealth != true)

            Button("Backup") { model?.backupSite() }
                .disabled(model?.canRunBackup != true)

            Divider()

            Button("Audit") { model?.auditSite() }
                .disabled(model?.canRunAudit != true)

            // Ellipsis items open a sheet for further input, per the HIG.
            Button("Harden…") { model?.harden.openSheet() }
                .disabled(model?.canRunHarden != true)

            Divider()

            Button("Domain…") { model?.domain.openSheet() }
                .disabled(model?.canOpenDomain != true)

            Button("Add Integration…") { model?.openIntegrationWizard() }
                .disabled(model?.canOpenIntegrationWizard != true)

            Button("Siri AI Readiness…") { model?.openSiriReadiness() }
                .disabled(model?.canOpenSiriReadiness != true)

            // No dedicated "Style Guide…" menu item exists to mirror (Style Guide is toolbar-only,
            // see `SiteWindow`'s `styleGuide` `ToolbarItem`) — this follows the sibling ellipsis
            // items above instead (#465).
            Button("Review Copy…") { model?.presentCopyEdit() }
                .disabled(model?.canOpenCopyEdit != true)

            #if !ANGLESITE_MAS
            // Same identity swap as the toolbar: menus rebuild on every open, so a state-dependent
            // item is fine here (unlike the customizable toolbar, see #519).
            if let remote = model?.publish.existingRemote {
                Button("View on GitHub") { NSWorkspace.shared.open(remote.url) }
            } else {
                Button("Publish to GitHub…") {
                    guard let model, let site = model.site else { return }
                    model.publish.publish(source: site.sourceDirectory, repoName: site.name)
                }
                .disabled(model?.canPublishToGitHub != true)
            }
            #endif

            Divider()

            // Dev-server lifecycle (#515). Start covers the stopped and failed states (the same
            // recovery as the preview pane's Retry button); Restart is for a wedged Astro process
            // that hasn't died. Enablement rules are `DevServerControls` in AnglesiteCore.
            Button("Start Dev Server") { model?.startDevServer() }
                .disabled(model?.canStartDevServer != true)

            Button("Stop Dev Server") { model?.stopDevServer() }
                .disabled(model?.canStopDevServer != true)

            // ⌥⌘R: plain ⌘R stays reserved for preview reload (#514).
            Button("Restart Dev Server") { model?.restartDevServer() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model?.canRestartDevServer != true)

            Divider()

            // The graph pane itself is View ▸ Graph ⌘3 (#512) — pane modes are View-menu domain.
            Button("Open in Browser") { model?.openPreviewInBrowser() }
                .disabled(model?.canOpenPreviewInBrowser != true)
        }
    }
}
