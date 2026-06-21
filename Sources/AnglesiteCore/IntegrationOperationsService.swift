// Sources/AnglesiteCore/IntegrationOperationsService.swift
import Foundation

public protocol IntegrationOperationsService: Sendable {
    func descriptors() -> [IntegrationDescriptor]
    func plan(integrationID: IntegrationID, answers: Answers, siteID: String) async -> Result<OperationPlan, IntegrationError>
    func apply(_ plan: OperationPlan, siteID: String) async -> IntegrationScaffolder.SetupStep
}

public struct IntegrationOperations: IntegrationOperationsService {
    private let sourceDirectory: @Sendable (String) async -> URL?
    private let templateDirectory: @Sendable () -> URL?
    private let scaffolder: IntegrationScaffolder

    public init(sourceDirectory: @escaping @Sendable (String) async -> URL?,
                templateDirectory: @escaping @Sendable () -> URL?) {
        self.sourceDirectory = sourceDirectory
        self.templateDirectory = templateDirectory
        self.scaffolder = IntegrationScaffolder()
    }

    public func descriptors() -> [IntegrationDescriptor] { IntegrationCatalog.all }

    public func plan(integrationID: IntegrationID, answers: Answers, siteID: String) async -> Result<OperationPlan, IntegrationError> {
        guard let source = await sourceDirectory(siteID) else { return .failure(.siteNotFound) }
        guard let template = templateDirectory() else { return .failure(.templateUnavailable) }
        return IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: integrationID),
                                       answers: answers, sourceDirectory: source, templateDirectory: template)
    }

    public func apply(_ plan: OperationPlan, siteID: String) async -> IntegrationScaffolder.SetupStep {
        guard let source = await sourceDirectory(siteID) else {
            return .failed(step: "resolve", message: "Couldn't find that site.")
        }
        var terminal: IntegrationScaffolder.SetupStep = .failed(step: "apply", message: "No steps ran.")
        for await s in scaffolder.apply(plan, in: source) {
            if case .done = s { terminal = s }
            if case .failed = s { terminal = s }
        }
        return terminal
    }
}
