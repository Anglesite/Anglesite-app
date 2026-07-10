// Sources/AnglesiteCore/DesignInterviewTool.swift
import Foundation

#if compiler(>=6.4)
import FoundationModels

/// Chat entry point for the design interview. Unlike `SetupIntegrationTool`/`SetupThemeTool`
/// (stateless plan-then-apply calls), the interview is inherently multi-turn — this tool's `call`
/// starts or continues a session-scoped `DesignInterviewModel` the caller supplies, rather than
/// owning conversation state itself.
public struct DesignInterviewTool: Tool, Sendable {
    public static let toolName = "designInterview"
    public let name = DesignInterviewTool.toolName
    public let description = "Have a short conversation to design or redesign a site's look and feel."

    @Generable
    public struct Arguments {
        @Guide(description: "The owner's message in this turn of the design conversation.")
        public var message: String
        @Guide(description: "Set to true if the owner wants Anglesite to just pick a design for them.")
        public var designForMe: Bool?
    }

    private let model: DesignInterviewModel
    public init(model: DesignInterviewModel) { self.model = model }

    public func call(arguments: Arguments) async throws -> String {
        if arguments.designForMe == true {
            let businessType = await MainActor.run { () -> String in
                model.skipToAxisConfirmation()
                return model.draft.businessType
            }
            return "I'll design it for you based on what a \(businessType) site usually needs. Review the axes and tell me to apply when you're happy."
        }
        await model.send(arguments.message)
        return await MainActor.run { model.transcript.last?.text ?? "" }
    }
}
#endif
