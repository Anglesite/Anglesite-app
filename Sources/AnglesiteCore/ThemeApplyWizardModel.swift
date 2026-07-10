// Sources/AnglesiteCore/ThemeApplyWizardModel.swift
import Foundation
import Observation

/// Drives the "apply a design" wizard: pick a source (built-in theme vs. a freedesignmd.com
/// system), pick within that source, review, then apply via `DesignApplyService`. Shared by both
/// the built-in theme gallery and the freedesignmd browsing flow so there is exactly one
/// wizard-state machine rather than one per source.
@MainActor @Observable
public final class ThemeApplyWizardModel: Identifiable {
    public enum Step: Int, CaseIterable { case pickSource, pickBuiltIn, browseFreedesignmd, review, applying }
    public enum Source: Equatable { case builtIn, freedesignmd }

    public let id = UUID()
    public var step: Step = .pickSource
    public var source: Source?
    public var selectedBuiltInID: String?
    public var freedesignmdCandidates: [FreedesignmdSystem] = []
    public var selectedFreedesignmdSlug: String?
    public var businessType: String
    public internal(set) var applyResult: Result<AppliedDesign, DesignApplyError>?
    public internal(set) var fetchError: String?

    public let catalog: ThemeCatalog
    private let package: AnglesitePackage
    private let session: URLSession

    public init(
        catalog: ThemeCatalog, businessType: String, package: AnglesitePackage, session: URLSession = .shared
    ) {
        self.catalog = catalog
        self.businessType = businessType
        self.package = package
        self.session = session
    }

    public var selectedBuiltInTheme: Theme? {
        selectedBuiltInID.flatMap(catalog.theme(id:))
    }

    public var canContinue: Bool {
        switch step {
        case .pickSource: return source != nil
        case .pickBuiltIn: return selectedBuiltInID != nil
        case .browseFreedesignmd: return selectedFreedesignmdSlug != nil
        case .review: return true
        case .applying: return false
        }
    }

    public func advance() async {
        guard canContinue else { return }
        switch step {
        case .pickSource:
            step = source == .builtIn ? .pickBuiltIn : .browseFreedesignmd
            if source == .freedesignmd { await loadFreedesignmdCandidates() }
        case .pickBuiltIn, .browseFreedesignmd:
            step = .review
        case .review, .applying:
            break
        }
    }

    public func back() {
        switch step {
        case .pickBuiltIn, .browseFreedesignmd: step = .pickSource
        case .review: step = source == .builtIn ? .pickBuiltIn : .browseFreedesignmd
        case .pickSource, .applying: break
        }
    }

    private func loadFreedesignmdCandidates() async {
        do {
            let all = try await FreedesignmdCatalog.fetchSystemList(session: session)
            freedesignmdCandidates = Array(FreedesignmdCatalog.rank(all, byKeywordsIn: businessType).prefix(10))
        } catch {
            fetchError = "Couldn't reach freedesignmd.com — \((error as NSError).localizedDescription)"
        }
    }

    public func apply() async {
        step = .applying
        switch source {
        case .builtIn:
            guard let theme = selectedBuiltInTheme else {
                applyResult = .failure(.writeFailed(message: "No theme selected to apply.", partiallyWritten: []))
                return
            }
            let input = DesignApplyInput(
                cssVars: DesignTokenWriter.templateCSSVars(for: theme),
                rationaleMarkdown: nil,
                brandSummary: theme.blurb,
                sourceLabel: "Built-in theme: \(theme.name)"
            )
            applyResult = DesignApplyService.apply(input, to: package)
        case .freedesignmd:
            guard let slug = selectedFreedesignmdSlug else {
                applyResult = .failure(.writeFailed(message: "No design system selected to apply.", partiallyWritten: []))
                return
            }
            let description = (try? await FreedesignmdCatalog.fetchDescription(slug: slug, session: session)) ?? nil
            // freedesignmd's per-system CSS-token translation (mapping a fetched DESIGN.md's
            // described tokens onto the template's 12 vars) is deliberately stubbed to `[:]` —
            // see the plan's Task 8/9 note. This flow currently only records the description as
            // brand rationale; it does not yet write new CSS vars.
            let input = DesignApplyInput(
                cssVars: [:],
                rationaleMarkdown: nil,
                brandSummary: description ?? "Applied from freedesignmd.com/system/\(slug).",
                sourceLabel: "freedesignmd: \(slug)"
            )
            applyResult = DesignApplyService.apply(input, to: package)
        case nil:
            applyResult = .failure(.writeFailed(message: "No design source selected to apply.", partiallyWritten: []))
        }
    }
}
