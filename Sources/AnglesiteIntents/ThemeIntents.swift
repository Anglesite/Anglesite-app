// Sources/AnglesiteIntents/ThemeIntents.swift
import AppIntents
import AnglesiteCore
import Foundation

/// Siri/Shortcuts front door for applying a built-in visual theme to a site.
///
/// `SiteEntity.directory` (set from `SiteStore.Site.packageURL` — see `SiteEntity.swift`) is the
/// `.anglesite` package root, not the `Source/` git directory. So this intent builds a real
/// `AnglesitePackage(url:)` from it and uses the package-based `DesignApplyService.apply`
/// overload, which re-derives `Source/` internally. (Contrast `SetupThemeTool` in
/// `AnglesiteCore`, which is handed an already-resolved `Source/` directory by the conversation
/// context and calls the `URL` overload directly — there is no phantom
/// `AnglesitePackage(sourceDirectory:)` initializer; it does not exist.)
public struct ApplyThemeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Apply Theme"
    public static let description = IntentDescription("Apply a built-in visual theme to a site.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "Theme", description: "e.g. warm, classic, bold, elegant.") public var themeID: String
    @Dependency private var catalog: ThemeCatalog

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Apply \(\.$themeID) theme to \(\.$site)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let theme = catalog.theme(id: themeID) else {
            let names = catalog.themes.map(\.name).joined(separator: ", ")
            return .result(dialog: IntentDialog(stringLiteral: "I don't recognize that theme. Available: \(names)."))
        }
        guard let packageURL = site.directory else {
            return .result(dialog: IntentDialog(stringLiteral: "I couldn't find \(site.displayName)'s location."))
        }
        try await requestConfirmation(dialog: "Apply the \(theme.name) theme to \(site.displayName)?")
        let package = AnglesitePackage(url: packageURL)
        let input = DesignApplyInput(
            cssVars: DesignTokenWriter.templateCSSVars(for: theme),
            rationaleMarkdown: nil,
            brandSummary: theme.blurb,
            sourceLabel: "Built-in theme: \(theme.name)"
        )
        let result = DesignApplyService.apply(input, to: package)
        return .result(dialog: IntentDialog(stringLiteral: SetupThemeArguments.reply(for: result, themeName: theme.name)))
    }
}
