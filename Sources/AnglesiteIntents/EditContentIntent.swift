import AppIntents
import AnglesiteCore
import Foundation

/// Phase B.5 (#149). Apply a natural-language instruction to an onscreen element.
///
/// **Wire-up:**
/// 1. Siri's `appEntityUIElementProvider` (B.4 / #148) resolves "this heading" / "that image"
///    into a concrete `ElementEntity` from `PreviewAnnotationProvider`.
/// 2. Siri fills `EditContentIntent`'s parameters with the entity + the user's spoken phrase
///    ("make it bigger", "change the color to teal", …).
/// 3. `perform()` decodes the entity's stored selector back into a structured `JSONValue`,
///    builds an `EditMessage`, and routes it via `IntentEditBridge` →
///    `EditRouterRegistry.shared` → the open window's `MCPApplyEditRouter` → plugin
///    `apply_edit` MCP tool.
/// 4. Plugin interprets the instruction (the natural-language op is the plugin's responsibility,
///    not the app's) and commits the patch.
/// 5. The reply's status drives the dialog: applied / failed / ambiguous, each phrased the way
///    Siri reads them aloud.
///
/// **Operation tag** is `"apply-instruction"` — forward-looking. The existing plugin op set
/// (`replace-text`, `replace-image-src`, `replace-attr`) doesn't accept free-form NL today, so
/// in-progress smoke testing will hit `.failed` until the paired plugin change ships. The
/// failure path is well-tested and the dialog explains the situation — shipping the app side
/// now unblocks the plugin work to land independently.
public struct EditContentIntent: AppIntent {
    public static var title: LocalizedStringResource = "Edit Content"
    public static var description = IntentDescription(
        "Apply a natural-language edit to an onscreen element of a site."
    )

    @Parameter(title: "Element") public var element: ElementEntity
    @Parameter(title: "Change") public var instruction: String
    @Dependency private var bridge: IntentEditBridge

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Change \(\.$element) — \(\.$instruction)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let resolved = IntentEditBridgeOverride.scoped ?? bridge
        guard let selector = element.selectorJSON() else {
            return .result(dialog: IntentDialog(stringLiteral: ContentDialogs.editInvalidSelector(
                displayName: element.displayName
            )))
        }
        let reply = await resolved.applyEdit(
            siteID: element.siteID,
            filePath: element.pagePath,
            selector: selector,
            op: "apply-instruction",
            value: .string(instruction)
        )
        let dialog = ContentDialogs.editReply(reply, displayName: element.displayName)
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

#if compiler(>=6.4)
// The MCP server may need to be spawned on first edit, which can exceed the default budget;
// gate by `LongRunningIntent` + `CancellableIntent` the way the create intents do (see
// `ContentIntents.swift`). Removed in #128 once macos-15 ships with Xcode 27.
extension EditContentIntent: LongRunningIntent, CancellableIntent {}
#endif

// MARK: - Dialog formatting (pure, unit-testable)

extension ContentDialogs {
    /// `.applied`-status dialog. Mentions the file the patch landed on when the plugin reports
    /// one (so "edit this heading" → "Edited h1 — Welcome in src/pages/about.astro.") and falls
    /// back to a shorter form otherwise.
    public static func editApplied(displayName: String, file: String?) -> String {
        if let file, !file.isEmpty {
            return "Edited \(displayName) in \(file)."
        }
        return "Edited \(displayName)."
    }

    /// `.failed`-status dialog. The plugin's reason (when present) is the most useful thing to
    /// say back to the user. Fall through to a generic phrasing otherwise.
    public static func editFailed(displayName: String, reason: String?) -> String {
        if let reason, !reason.isEmpty {
            return "Couldn’t edit \(displayName): \(reason)"
        }
        return "Couldn’t edit \(displayName)."
    }

    /// `.ambiguous`-status dialog. Distinct from `.failed` because the user can rephrase and try
    /// again — wording acknowledges the ambiguity rather than blaming a hard error.
    public static func editAmbiguous(displayName: String, detail: String?) -> String {
        if let detail, !detail.isEmpty {
            return "Not sure how to edit \(displayName): \(detail)"
        }
        return "Not sure how to edit \(displayName) — try rephrasing."
    }

    /// When the entity's stored selector won't decode back into the structured shape
    /// `EditMessage` requires. Shouldn't happen at runtime (the encoder/decoder round-trip is
    /// tested), but the failure mode is well-defined enough to deserve a dialog.
    public static func editInvalidSelector(displayName: String) -> String {
        "Lost track of \(displayName) — try selecting it again."
    }

    /// Dispatch on the reply status. Single entry point the intent's `perform()` uses.
    public static func editReply(_ reply: EditReply, displayName: String) -> String {
        switch reply.status {
        case .applied: return editApplied(displayName: displayName, file: reply.file)
        case .failed: return editFailed(displayName: displayName, reason: reply.message)
        case .ambiguous: return editAmbiguous(displayName: displayName, detail: reply.message)
        }
    }
}
