// Sources/AnglesiteCore/IntegrationOperationsService.swift
import Foundation

public protocol IntegrationOperationsService: Sendable {
    func descriptors() -> [IntegrationDescriptor]
    func plan(integrationID: IntegrationID, answers: Answers, siteID: String) async -> Result<OperationPlan, IntegrationError>
    func apply(_ plan: OperationPlan, siteID: String) async -> IntegrationScaffolder.SetupStep
}

// FileManager is documented thread-safe for the shared `.default` singleton; wrap it in
// @unchecked Sendable so it can be stored in a Sendable struct and passed across isolation
// boundaries without suppressing the warning at every call-site.
private struct SendableFileManager: @unchecked Sendable {
    let value: FileManager
}

public struct IntegrationOperations: IntegrationOperationsService {
    private let sourceDirectory: @Sendable (String) async -> URL?
    private let templateDirectory: @Sendable () -> URL?
    private let scaffolder: IntegrationScaffolder
    private let fm: SendableFileManager

    public init(sourceDirectory: @escaping @Sendable (String) async -> URL?,
                templateDirectory: @escaping @Sendable () -> URL?,
                fileManager: FileManager = .default) {
        self.sourceDirectory = sourceDirectory
        self.templateDirectory = templateDirectory
        self.fm = SendableFileManager(value: fileManager)
        // Wrap in SendableFileManager to cross the actor-init isolation boundary cleanly.
        let sfm = SendableFileManager(value: fileManager)
        self.scaffolder = IntegrationScaffolder(fileManager: sfm.value)
    }

    public func descriptors() -> [IntegrationDescriptor] { IntegrationCatalog.all }

    public func plan(integrationID: IntegrationID, answers: Answers, siteID: String) async -> Result<OperationPlan, IntegrationError> {
        guard let source = await sourceDirectory(siteID) else { return .failure(.siteNotFound) }
        guard let template = templateDirectory() else { return .failure(.templateUnavailable) }
        return IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: integrationID),
                                       answers: answers, sourceDirectory: source, templateDirectory: template,
                                       fileManager: fm.value)
    }

    public func apply(_ plan: OperationPlan, siteID: String) async -> IntegrationScaffolder.SetupStep {
        guard let source = await sourceDirectory(siteID) else {
            return .failed(step: "resolve", message: "Couldn't find that site.")
        }
        var terminal: IntegrationScaffolder.SetupStep? = nil
        for await s in scaffolder.apply(plan, in: source) {
            if case .done = s { terminal = s }
            if case .failed = s { terminal = s }
        }
        return terminal ?? .failed(step: "apply", message: "No steps ran.")
    }
}

public extension IntegrationOperations {
    /// The production instance: resolves a site id to its `Source/` dir via `SiteStore.shared`
    /// and the template root via `TemplateRuntime`. Single construction path for every front-door.
    static func live() -> IntegrationOperations {
        IntegrationOperations(
            sourceDirectory: { id in await SiteStore.shared.find(id: id)?.sourceDirectory },
            templateDirectory: { TemplateRuntime.resolve().url }
        )
    }
}
