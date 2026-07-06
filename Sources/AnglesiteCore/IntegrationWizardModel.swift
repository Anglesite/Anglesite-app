// Sources/AnglesiteCore/IntegrationWizardModel.swift
import Foundation
import Observation

@MainActor @Observable
public final class IntegrationWizardModel: Identifiable {
    public enum Step: Int, CaseIterable { case pickIntegration, pickProvider, fields, review, applying }

    public let id = UUID()
    public var step: Step = .pickIntegration
    public var selectedID: IntegrationID?
    public var answers: Answers = [:]
    public internal(set) var plan: OperationPlan?
    public internal(set) var planError: String?
    public internal(set) var progress: [IntegrationScaffolder.SetupStep] = []

    private let service: any IntegrationOperationsService
    private let siteID: String

    public init(service: any IntegrationOperationsService, siteID: String) {
        self.service = service
        self.siteID = siteID
    }

    public var descriptor: IntegrationDescriptor? {
        guard let id = selectedID else { return nil }
        return service.descriptors().first { $0.id == id }
    }

    public var descriptorsForPicker: [IntegrationDescriptor] { service.descriptors() }

    public var visibleFields: [Field] {
        guard let descriptor else { return [] }
        let provider = answers["provider"]
        return descriptor.fields.filter { IntegrationPlanner.isVisible($0.visibleWhen, answers: answers, providerID: provider) }
    }

    public var canContinue: Bool {
        switch step {
        case .pickIntegration: return selectedID != nil
        case .pickProvider: return answers["provider"] != nil
        case .fields:
            return visibleFields.allSatisfy { $0.isOptional || !($0.value(in: answers)).isEmpty }
        case .review: return plan != nil
        case .applying: return false
        }
    }

    public func advance() async {
        // Skip the provider step for provider-less integrations (e.g. giscus).
        if step == .pickIntegration, descriptor?.providers.isEmpty == true {
            step = .fields; return
        }
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
        if step == .review, let id = selectedID {
            // Clear any stale plan synchronously before the async call so the UI never shows
            // a previous result while a new one is in flight.
            plan = nil
            planError = nil
            let result = await service.plan(integrationID: id, answers: answers, siteID: siteID)
            switch result {
            case .success(let p):
                plan = p
                planError = nil
            case .failure(let error):
                plan = nil
                let descriptor = service.descriptors().first { $0.id == id }
                    ?? IntegrationCatalog.descriptor(for: id)
                planError = SetupIntegrationArguments.reply(for: .failure(error), descriptor: descriptor)
            }
        }
    }

    public func back() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        // Mirror advance()'s forward-skip: a provider-less integration (e.g. giscus) never shows the
        // provider step, so backing out of .fields must hop straight to .pickIntegration rather than
        // strand the user on an empty .pickProvider screen (where canContinue would be false).
        if prev == .pickProvider, descriptor?.providers.isEmpty == true {
            step = .pickIntegration
            return
        }
        step = prev
    }

    /// Entry point for the "Add a Store" router: jumps straight to `.fields` (or `.pickProvider`
    /// if the router didn't resolve a provider, e.g. `.donations`) instead of going through
    /// `.pickIntegration`/`.pickProvider` in order — the router already answered those questions.
    ///
    /// Resets `answers` first: this model persists for the whole wizard session (one instance per
    /// open sheet, not per attempt), so a second "Add a Store" attempt after backing out of a first
    /// would otherwise carry over stale field values — e.g. `buyButton` and `lemonSqueezy` share the
    /// `checkoutUrl`/`buttonText` field keys, so switching categories could pre-fill the wrong
    /// platform's data, and a stale `answers["provider"]` could satisfy `.pickProvider`'s
    /// `canContinue` without the user ever choosing a provider for the new integration.
    public func startFromRouter(_ route: AddStoreRouter.Route) {
        answers = [:]
        selectedID = route.integrationID
        if let provider = route.presetProvider {
            answers["provider"] = provider
        }
        step = (descriptor?.providers.isEmpty == true || route.presetProvider != nil) ? .fields : .pickProvider
    }

    public func apply() async {
        guard let plan else { return }
        step = .applying
        let terminal = await service.apply(plan, siteID: siteID)
        progress.append(terminal)
    }
}

private extension Field {
    func value(in answers: Answers) -> String { answers[key] ?? defaultValue ?? "" }
}
