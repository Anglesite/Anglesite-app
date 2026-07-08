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
                .disabled(model?.site == nil)

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
                .disabled(model == nil || model?.domain.isRunning == true)

            Button("Add Integration…") { model?.openIntegrationWizard() }
                .disabled(model?.site == nil)

            Button("Siri AI Readiness…") { model?.openSiriReadiness() }
                .disabled(model?.canOpenSiriReadiness != true || model?.site == nil)

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
                .disabled(model?.site?.isValid != true || model?.publish.isRunning == true)
            }
            #endif

            Divider()

            Button("Open in Browser") { model?.openPreviewInBrowser() }
                .disabled(model?.preview.readyURL == nil)

            Button("Show Site Graph") {
                guard let model else { return }
                Task { await model.showGraph() }
            }
            .disabled(model?.site == nil)
        }
    }
}
