import Foundation

/// Pure, non-gated helpers for the FM tool, so the parse/reply logic is unit-testable on CI.
public enum SetupIntegrationArguments {
    public static func parseConfig(_ raw: String?) -> Answers {
        guard let raw, !raw.isEmpty else { return [:] }
        var out: Answers = [:]
        for pair in raw.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            out[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    public static func id(for type: String) -> IntegrationID? { IntegrationID(rawValue: type) }

    /// Turn a plan result into a chat reply: re-prompt on missing field, else a confirm-before-apply summary.
    public static func reply(for result: Result<OperationPlan, IntegrationError>,
                             descriptor: IntegrationDescriptor) -> String {
        switch result {
        case .success(let plan):
            return "Here's what I'll set up:\n\(plan.summary)\n\nConfirm to apply, or tell me what to change."
        case .failure(.missingRequiredField(let key)):
            let label = descriptor.fields.first { $0.key == key }?.label ?? key
            return "I need the \(label) to continue."
        case .failure(.providerRequired):
            let names = descriptor.providers.map(\.displayName).joined(separator: ", ")
            return "Which provider would you like? Options: \(names)."
        case .failure(.unknownProvider(let p)):
            return "I don't recognize the provider \"\(p)\"."
        case .failure(.invalidValue(let key, let reason)):
            let label = descriptor.fields.first { $0.key == key }?.label ?? key
            return "The \(label) looks off — \(reason)."
        case .failure(.siteNotFound):
            return "I couldn't find that site."
        case .failure(.templateUnavailable):
            return "The site template isn't available right now."
        }
    }
}

#if compiler(>=6.4)
import FoundationModels

public struct SetupIntegrationTool: Tool, Sendable {
    public static let toolName = "setupIntegration"
    public let name = SetupIntegrationTool.toolName
    public let description = "Set up a website integration (booking, donations, or giscus comments). Returns a plan to confirm before applying."

    @Generable
    public struct Arguments {
        @Guide(description: "Integration to add: 'booking', 'donations', or 'giscus'.")
        public var integrationType: String
        @Guide(description: "Provider id when the integration needs one (e.g. 'cal', 'calendly', 'stripe').")
        public var provider: String?
        @Guide(description: "Field values as key=value pairs, comma-separated (e.g. 'username=jane,style=inline').")
        public var config: String?
    }

    private let service: any IntegrationOperationsService
    private let siteID: String
    public init(service: any IntegrationOperationsService, siteID: String) {
        self.service = service; self.siteID = siteID
    }

    public func call(arguments: Arguments) async throws -> String {
        guard let id = SetupIntegrationArguments.id(for: arguments.integrationType) else {
            return "I can set up booking, donations, or giscus comments. Which one?"
        }
        var answers = SetupIntegrationArguments.parseConfig(arguments.config)
        if let p = arguments.provider { answers["provider"] = p }
        let result = await service.plan(integrationID: id, answers: answers, siteID: siteID)
        return SetupIntegrationArguments.reply(for: result, descriptor: IntegrationCatalog.descriptor(for: id))
    }
}
#endif
