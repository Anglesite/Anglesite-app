import Foundation

/// A lean, test-enforced description of a Siri-facing Anglesite operation. Captures only what the
/// auto-derived system-MCP schema (`mcpbridge`) cannot express — side-effect level, confirmation,
/// cancellability, and a human-readable result label — so Siri, Shortcuts, and system MCP stay
/// consistent with the real intents without re-declaring parameters (those flow from `@Parameter` /
/// `@Property` via D.2). Spec: docs/superpowers/specs/2026-06-19-operation-descriptors-design.md.
public struct OperationDescriptor: Sendable, Equatable {
    /// Stable slug, e.g. "deploy-site". Unique across the registry.
    public let operationID: String
    /// Human-facing name; matches the intent's `title`, e.g. "Deploy Site".
    public let displayName: String
    /// The intent's Swift type name, e.g. "DeploySiteIntent". The coverage-anchor key; unique.
    public let intentTypeName: String
    public let sideEffect: OperationSideEffect
    public let requiresConfirmation: Bool
    public let isCancellable: Bool
    public let resultShape: OperationResult
    /// The `mcpbridge`-assigned tool name, once Apple's naming convention is pinned (D.5/#166).
    /// `nil` for all current entries — forward-looking, not asserted by any test.
    public let mcpToolName: String?

    public init(
        operationID: String,
        displayName: String,
        intentTypeName: String,
        sideEffect: OperationSideEffect,
        requiresConfirmation: Bool,
        isCancellable: Bool,
        resultShape: OperationResult,
        mcpToolName: String? = nil
    ) {
        self.operationID = operationID
        self.displayName = displayName
        self.intentTypeName = intentTypeName
        self.sideEffect = sideEffect
        self.requiresConfirmation = requiresConfirmation
        self.isCancellable = isCancellable
        self.resultShape = resultShape
        self.mcpToolName = mcpToolName
    }
}

/// Mutation risk to a site's content *source* — what drives confirmation decisions. Operations that
/// spawn subprocesses but don't touch site source (audit, preview, status, search) are `.readOnly`.
public enum OperationSideEffect: Sendable, Equatable {
    case readOnly
    case createsContent
    case modifiesContent
    case publishes
}

/// The shape an agent gets back. The associated string is the entity type name.
public enum OperationResult: Sendable, Equatable {
    case none
    case entity(String)
    case entities(String)
}

/// The canonical registry — the single source of truth for Siri-facing operation metadata.
public enum AnglesiteOperations {
    public static let all: [OperationDescriptor] = [
        OperationDescriptor(
            operationID: "deploy-site", displayName: "Deploy Site",
            intentTypeName: "DeploySiteIntent", sideEffect: .publishes,
            requiresConfirmation: true, isCancellable: true,
            resultShape: .entity("SiteEntity")
        ),
        OperationDescriptor(
            operationID: "backup-site", displayName: "Back Up Site",
            intentTypeName: "BackupSiteIntent", sideEffect: .modifiesContent,
            requiresConfirmation: false, isCancellable: true,
            resultShape: .entity("SiteEntity")
        ),
        OperationDescriptor(
            operationID: "audit-site", displayName: "Check Site",
            intentTypeName: "AuditSiteIntent", sideEffect: .readOnly,
            requiresConfirmation: false, isCancellable: true,
            resultShape: .entity("SiteEntity")
        ),
        OperationDescriptor(
            operationID: "open-site", displayName: "Open Site",
            intentTypeName: "OpenSiteIntent", sideEffect: .readOnly,
            requiresConfirmation: false, isCancellable: false,
            resultShape: .none
        ),
        OperationDescriptor(
            operationID: "search-content", displayName: "Search Site Content",
            intentTypeName: "SearchContentIntent", sideEffect: .readOnly,
            requiresConfirmation: false, isCancellable: false,
            resultShape: .entities("ContentMatchEntity")
        ),
        OperationDescriptor(
            operationID: "site-status", displayName: "Site Content Status",
            intentTypeName: "SiteStatusIntent", sideEffect: .readOnly,
            requiresConfirmation: false, isCancellable: false,
            resultShape: .none
        ),
        OperationDescriptor(
            operationID: "preview-site", displayName: "Preview Site",
            intentTypeName: "PreviewSiteIntent", sideEffect: .readOnly,
            requiresConfirmation: false, isCancellable: false,
            resultShape: .none
        ),
        OperationDescriptor(
            operationID: "add-page", displayName: "Add Page",
            intentTypeName: "AddPageIntent", sideEffect: .createsContent,
            requiresConfirmation: false, isCancellable: true,
            resultShape: .entity("PageEntity")
        ),
        OperationDescriptor(
            operationID: "add-post", displayName: "Add Post",
            intentTypeName: "AddPostIntent", sideEffect: .createsContent,
            requiresConfirmation: false, isCancellable: true,
            resultShape: .entity("PostEntity")
        ),
        OperationDescriptor(
            operationID: "edit-content", displayName: "Edit Content",
            intentTypeName: "EditContentIntent", sideEffect: .modifiesContent,
            requiresConfirmation: false, isCancellable: true,
            resultShape: .none
        ),
    ]

    /// Look up a descriptor by intent type name. `nil` if none registered.
    public static func descriptor(forIntentTypeName name: String) -> OperationDescriptor? {
        all.first { $0.intentTypeName == name }
    }
}
