/// Test seam for the confirmation outcome. `requestConfirmation` is not introspectable under
/// `swift test` (no intentsd / registered app), so the decline-path test drives this instead.
public enum ConfirmationDecision: Sendable { case confirm, decline }

public enum ConfirmationOverride {
    @TaskLocal public static var scoped: ConfirmationDecision?
}
