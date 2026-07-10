import Foundation
import Observation
import AnglesiteSiteModel

/// Drives one design-interview conversation: prompts the current ``ConversationStage`` through an
/// injected ``ConversationalAssistant``, appends turns to a transcript, and — once the owner
/// confirms the resulting ``DesignAxes`` — applies the generated design via ``DesignApplyService``.
///
/// Depends on the toolchain-independent ``ConversationalAssistant`` protocol (already used by
/// `FoundationModelAssistant`'s conformance) rather than the concrete gated type directly, so the
/// model itself stays testable on any toolchain with a fake assistant — the same seam
/// `SiteGraphNodeExplaining` uses to decouple `SiteGraphExplainerFactory`'s consumers from the
/// FoundationModels-gated implementation.
@MainActor @Observable
public final class DesignInterviewModel: Identifiable {
    public let id = UUID()
    public internal(set) var draft: DesignInterviewDraft
    public internal(set) var transcript: [(role: String, text: String)] = []
    public internal(set) var applyResult: Result<AppliedDesign, DesignApplyError>?

    private let assistant: any ConversationalAssistant
    private let package: AnglesitePackage
    private let siteID: String

    public init(businessType: String, assistant: any ConversationalAssistant, package: AnglesitePackage, siteID: String = "") {
        self.draft = DesignInterviewDraft(businessType: businessType)
        self.assistant = assistant
        self.package = package
        self.siteID = siteID
    }

    /// Sends one turn: appends the user's message, prompts the current stage, appends the
    /// assistant's reply, then advances the conversation to the next stage. Structured
    /// (`@Generable`) axis extraction from the reply is a follow-up refinement — v1 advances on
    /// any reply and lets the user correct axes via ``nudge(_:)``.
    public func send(_ userMessage: String) async {
        transcript.append((role: "user", text: userMessage))
        let prompt = DesignInterviewPrompts.prompt(for: draft.stage, draft: draft, userMessage: userMessage)
        let context = AssistantContext(siteID: siteID, siteDirectory: package.sourceURL)
        guard let stream = try? await assistant.converse(prompt: prompt, context: context) else {
            transcript.append((role: "assistant", text: "I couldn't respond just now — try again in a moment."))
            return
        }
        var reply = ""
        var failureMessage: String?
        for await event in stream {
            switch event {
            case .textDelta(let delta):
                reply += delta
            case .failed(let message):
                failureMessage = message
            case .cancelled:
                failureMessage = "The response was cancelled — try again."
            default:
                break
            }
        }
        if let failureMessage {
            transcript.append((role: "assistant", text: "I couldn't respond just now — \(failureMessage)"))
            return
        }
        transcript.append((role: "assistant", text: reply))
        draft.advance()
    }

    public func nudge(_ hint: DesignAdjectiveHint) {
        draft.applyAdjectiveHint(hint)
    }

    /// "Design it for me" escape hatch: skip straight to axis confirmation using the
    /// business-type defaults already seeded in `draft.axes`.
    public func skipToAxisConfirmation() {
        draft.stage = .axisConfirmation
    }

    public func confirmAndApply() async {
        let config = DesignConfigGenerator.config(axes: draft.axes, siteType: draft.businessType, brandColor: draft.brandColorHex)
        let input = DesignApplyInput(
            cssVars: DesignTokenWriter.templateCSSVars(for: config),
            rationaleMarkdown: DesignTokenWriter.rationaleMarkdown(for: config),
            brandSummary: "Generated from a design interview for a \(draft.businessType).",
            sourceLabel: "design-interview"
        )
        let result = DesignApplyService.apply(input, to: package)
        applyResult = result
        if case .success = result {
            draft.stage = .done
        }
    }
}
