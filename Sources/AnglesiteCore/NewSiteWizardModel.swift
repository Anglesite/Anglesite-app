import Foundation
import Observation

@MainActor
@Observable
public final class NewSiteWizardModel {
    public enum Step: Int, CaseIterable { case type, details, look, content, building }

    public var step: Step = .type
    public var draft = NewSiteDraft(siteType: .business, name: "")
    public private(set) var progress: [SiteScaffolder.ScaffoldStep] = []
    public private(set) var fatal: SiteScaffolder.ScaffoldStep?   // .failed, if any
    public private(set) var completedSiteID: String?

    public let catalog: ThemeCatalog
    private let slugTaken: @Sendable (String) -> Bool

    public init(catalog: ThemeCatalog, slugTaken: @escaping @Sendable (String) -> Bool) {
        self.catalog = catalog
        self.slugTaken = slugTaken
        // Seed a default theme for the initial type.
        draft.themeID = catalog.defaultThemeID(for: draft.siteType)
    }

    public var slugPreview: String { SiteSlug.derive(from: draft.name) }

    /// Non-fatal warnings collected during the build (e.g. dependencies failed to install). The
    /// wizard surfaces these instead of silently opening the site on success — otherwise the owner
    /// only discovers a failed `npm install` via a dead-end "Can't preview" screen (#229).
    public var warnings: [String] {
        progress.compactMap { if case .warning(_, let message) = $0 { return message } else { return nil } }
    }

    public var hasWarnings: Bool { !warnings.isEmpty }

    /// True once the build registered the site *and* produced no warnings — only then may the wizard
    /// open the site immediately. With warnings, the wizard stays on the building step so the owner
    /// can read them and open explicitly (#229).
    public var didCompleteCleanly: Bool { completedSiteID != nil && !hasWarnings }

    public var detailsError: String? {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return nil }              // empty is "incomplete", not an error to show
        if slugTaken(slugPreview) { return "A site named \u{201C}\(slugPreview)\u{201D} already exists." }
        return nil
    }

    public var canContinue: Bool {
        switch step {
        case .type:    return true
        case .details: return !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && detailsError == nil
        case .look:    return catalog.theme(id: draft.themeID) != nil
        case .content: return true                  // content is optional
        case .building: return false
        }
    }

    public func choose(type: SiteType) {
        draft.siteType = type
        draft.themeID = catalog.defaultThemeID(for: type)
    }

    public func advance() { if let next = Step(rawValue: step.rawValue + 1) { step = next } }
    public func back() { if let prev = Step(rawValue: step.rawValue - 1) { step = prev } }

    /// Runs the scaffolder, accumulating progress. Returns the new site id on success.
    public func build(using scaffolder: SiteScaffolder) async -> String? {
        step = .building
        if draft.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.headline = draft.name
        }
        for await s in scaffolder.scaffold(draft) {
            progress.append(s)
            if case .failed = s { fatal = s }
            if case .done(let id) = s { completedSiteID = id }
        }
        return completedSiteID
    }
}
