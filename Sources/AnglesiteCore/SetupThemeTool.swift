// Sources/AnglesiteCore/SetupThemeTool.swift
import Foundation

/// Pure, non-gated helpers so parse/reply logic is unit-testable on CI, mirroring
/// `SetupIntegrationArguments`.
public enum SetupThemeArguments {
    public static func reply(for result: Result<AppliedDesign, DesignApplyError>, themeName: String) -> String {
        switch result {
        case .success:
            return "Applied the \(themeName) theme."
        case .failure(.missingGlobalCSS):
            return "I couldn't find this site's stylesheet, so I couldn't apply \(themeName)."
        case .failure(.missingRootBlock):
            return "This site's stylesheet doesn't have the expected structure, so I couldn't apply \(themeName)."
        case .failure(.writeFailed(let message, let partiallyWritten)):
            guard !partiallyWritten.isEmpty else {
                return "Applying \(themeName) failed: \(message)."
            }
            let files = partiallyWritten.joined(separator: ", ")
            return "Applying \(themeName) failed partway through: \(message). Some files were already updated (\(files)) — the site may be in a mixed state until you try again."
        }
    }
}

#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels

public struct SetupThemeTool: Tool, Sendable {
    public static let toolName = "setupTheme"
    public let name = SetupThemeTool.toolName
    public let description = "Apply one of the built-in visual themes to the current site."

    @Generable
    public struct Arguments {
        @Guide(description: "The theme id to apply, e.g. 'warm', 'classic', 'bold'.")
        public var themeID: String
    }

    private let catalog: ThemeCatalog
    /// The site's `Source/` directory — the same value `AssistantContext.siteDirectory` carries,
    /// which `DesignApplyService.apply(_:to:)`'s `URL` overload expects directly. (Not an
    /// `AnglesitePackage`: the package-based overload re-derives `Source/` from a package root,
    /// and the conversation context only ever hands tools the already-resolved source directory.)
    private let sourceDirectory: URL

    public init(catalog: ThemeCatalog, sourceDirectory: URL) {
        self.catalog = catalog
        self.sourceDirectory = sourceDirectory
    }

    public func call(arguments: Arguments) async throws -> String {
        guard let theme = catalog.theme(id: arguments.themeID) else {
            let names = catalog.themes.map(\.name).joined(separator: ", ")
            return "I don't recognize that theme. Available themes: \(names)."
        }
        let input = DesignApplyInput(
            cssVars: DesignTokenWriter.templateCSSVars(for: theme),
            rationaleMarkdown: nil,
            brandSummary: theme.blurb,
            sourceLabel: "Built-in theme: \(theme.name)"
        )
        let result = DesignApplyService.apply(input, to: sourceDirectory)
        return SetupThemeArguments.reply(for: result, themeName: theme.name)
    }
}
#endif
