import Foundation

/// Which editor surface a navigator file opens in. v1 ships only `.text`; future cases
/// (`.metadataForm`, etc.) slot in by extending this enum and the `resolve(for:)` mapping —
/// call sites switch on the kind and need no change beyond adding the new view.
public enum EditorKind: Sendable, Equatable {
    case text
    // future: case metadataForm

    /// Resolves the editor for a file. A single decision point so the routing rule lives in one
    /// tested place; kept on the enum to keep the public API surface tidy.
    public static func resolve(for file: FileRef) -> EditorKind {
        .text
    }
}
