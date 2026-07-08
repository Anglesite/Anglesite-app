import Foundation

/// Bridges app-applied edits into a window's `UndoManager` so Edit ▸ Undo (⌘Z) reverses them (#527).
///
/// This sits at the shared edit-pipeline level, not inside any one assistant: every applied
/// edit with a commit — overlay drops, chat/assistant tool edits, alt-text follow-ups — flows
/// through `MCPApplyEditRouter.onEdit` into the app's edit recorder, which registers a
/// ``Record`` here at apply time. The reverse-apply itself is the plugin's git-revert
/// (`undo_edit`, wrapped by ``UndoCommand``), so the record only needs the commit SHA and the
/// row identity — the injected `perform` closure delegates to the existing inverse-application
/// + conflict-detection path (`ChatModel.undoEdit`).
///
/// The app-target glue stays thin: set ``undoManager`` from SwiftUI's
/// `@Environment(\.undoManager)` and supply `perform`; everything else lives here where it's
/// unit-testable against a plain Foundation `UndoManager`.
///
/// Policy notes:
/// - **No redo.** The plugin exposes revert (`undo_edit`) but no re-apply primitive, so
///   ``perform`` runs without registering an inverse — after ⌘Z, Edit ▸ Redo stays disabled.
/// - **LIFO matches git.** `UndoManager` pops newest-first, which is exactly the head-first
///   order the edits branch wants reverts in.
/// - **Out-of-band undos invalidate their record.** When an edit is undone by another path
///   (the chat row's Undo button), call ``invalidate(editID:)`` so ⌘Z doesn't replay a stale
///   action. Each record registers against its own private token target, so removal is
///   per-record (`removeAllActions(withTarget:)` on that token), not stack-wide.
@MainActor
public final class EditUndoCoordinator {
    /// One applied edit, as registered on the undo stack.
    public struct Record: Sendable, Equatable {
        /// Identity of the edit row in the transcript (`ChatMessage.id`) — what the perform
        /// closure uses to locate the row and flip its `undone` flag.
        public let editID: UUID
        /// Source file the edit landed on (site-relative path). Drives the menu action name.
        public let file: String
        /// SHA of the commit on `refs/heads/anglesite/edits` that captures this edit.
        public let commit: String

        public init(editID: UUID, file: String, commit: String) {
            self.editID = editID
            self.file = file
            self.commit = commit
        }
    }

    /// Kicks off the reverse-apply for one record. Called on the main actor when the user
    /// invokes Edit ▸ Undo; implementations typically spawn a `Task` for the async MCP call.
    public typealias Performer = @MainActor (Record) -> Void

    /// Per-record registration target. `UndoManager` does not retain targets, so each token is
    /// kept alive by the registered handler capturing it — its lifetime is exactly the
    /// lifetime of its undo-stack entry — and indexed in ``tokens`` for selective removal.
    private final class Token {
        let record: Record
        init(_ record: Record) { self.record = record }
    }

    /// The focused window's undo manager. Weak: the window owns it; this coordinator only
    /// registers into it. `nil` (no window attached yet) makes ``registerApplied(_:)`` a no-op.
    public weak var undoManager: UndoManager?

    private let perform: Performer
    /// Live registrations by edit ID, so ``invalidate(editID:)`` can remove exactly one
    /// record's action. Entries are dropped when their undo fires or they're invalidated.
    private var tokens: [UUID: Token] = [:]

    public init(perform: @escaping Performer) {
        self.perform = perform
    }

    /// Registers an applied edit on the undo stack. Call at apply time, right after the edit
    /// row is recorded. No-op when no ``undoManager`` is attached.
    public func registerApplied(_ record: Record) {
        guard let undoManager else { return }
        let token = Token(record)
        tokens[record.editID] = token
        // `token` is captured strongly by the handler on purpose: UndoManager holds its target
        // unsafely-unretained, so the capture pins the token (and nothing else — self is weak)
        // for exactly as long as the stack entry exists.
        undoManager.registerUndo(withTarget: token) { [weak self, token] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tokens[token.record.editID] = nil
                self.perform(token.record)
            }
        }
        undoManager.setActionName(Self.actionName(for: record))
    }

    /// Removes a still-pending record from the undo stack — call after an edit was undone via
    /// another path (e.g. the chat row's Undo button) so ⌘Z skips it. No-op for unknown or
    /// already-fired records.
    public func invalidate(editID: UUID) {
        guard let token = tokens.removeValue(forKey: editID) else { return }
        undoManager?.removeAllActions(withTarget: token)
    }

    /// Menu action name for a record: "Edit <filename>" → the menu shows "Undo Edit <filename>".
    public static func actionName(for record: Record) -> String {
        let filename = record.file.split(separator: "/").last.map(String.init) ?? record.file
        return "Edit \(filename)"
    }
}
