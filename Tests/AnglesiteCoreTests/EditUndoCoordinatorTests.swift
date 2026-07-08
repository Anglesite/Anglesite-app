import Foundation
import Testing
@testable import AnglesiteCore

/// Unit tests for ``EditUndoCoordinator`` — the AnglesiteCore piece of #527 that turns each
/// applied edit into a window `UndoManager` record so Edit ▸ Undo (⌘Z) reverses it.
///
/// Every test drives a real Foundation `UndoManager` (no window needed): registration,
/// LIFO pops, selective invalidation, and the no-redo policy are all observable through
/// `canUndo`/`canRedo`/`undoActionName` plus the injected perform closure.
@MainActor
struct EditUndoCoordinatorTests {
    private final class PerformSpy {
        var performed: [EditUndoCoordinator.Record] = []
    }

    private func makeCoordinator(undoManager: UndoManager?) -> (EditUndoCoordinator, PerformSpy) {
        let spy = PerformSpy()
        let coordinator = EditUndoCoordinator { record in
            spy.performed.append(record)
        }
        coordinator.undoManager = undoManager
        return (coordinator, spy)
    }

    private func record(
        editID: UUID = UUID(),
        file: String = "src/pages/index.astro",
        commit: String = "abcd1234"
    ) -> EditUndoCoordinator.Record {
        EditUndoCoordinator.Record(editID: editID, file: file, commit: commit)
    }

    @Test func registeredEditIsUndoableAndUndoPerformsIt() {
        let undoManager = UndoManager()
        let (coordinator, spy) = makeCoordinator(undoManager: undoManager)
        let record = record()

        #expect(!undoManager.canUndo)
        coordinator.registerApplied(record)
        #expect(undoManager.canUndo)

        undoManager.undo()

        #expect(spy.performed == [record])
        #expect(!undoManager.canUndo)
    }

    @Test func actionNameCarriesTheEditedFilename() {
        let undoManager = UndoManager()
        let (coordinator, _) = makeCoordinator(undoManager: undoManager)

        coordinator.registerApplied(record(file: "src/pages/about.astro"))

        #expect(undoManager.undoActionName == "Edit about.astro")
    }

    @Test func undoDoesNotRegisterARedo() {
        let undoManager = UndoManager()
        let (coordinator, _) = makeCoordinator(undoManager: undoManager)

        coordinator.registerApplied(record())
        undoManager.undo()

        // Reverse-apply is a git revert via the plugin's `undo_edit`; there is no re-apply
        // primitive, so the coordinator must not put anything on the redo stack.
        #expect(!undoManager.canRedo)
    }

    @Test func multipleEditsUndoInLIFOOrder() {
        let undoManager = UndoManager()
        let (coordinator, spy) = makeCoordinator(undoManager: undoManager)
        let first = record(file: "src/pages/index.astro", commit: "c1")
        let second = record(file: "src/pages/about.astro", commit: "c2")

        coordinator.registerApplied(first)
        coordinator.registerApplied(second)

        undoManager.undo()
        #expect(spy.performed == [second])
        undoManager.undo()
        #expect(spy.performed == [second, first])
    }

    @Test func registeringWithoutAnUndoManagerIsANoOp() {
        let (coordinator, spy) = makeCoordinator(undoManager: nil)

        coordinator.registerApplied(record())

        #expect(spy.performed.isEmpty)
    }

    @Test func invalidateRemovesTheRecordFromTheUndoStack() {
        let undoManager = UndoManager()
        let (coordinator, spy) = makeCoordinator(undoManager: undoManager)
        let record = record()

        coordinator.registerApplied(record)
        coordinator.invalidate(editID: record.editID)

        #expect(!undoManager.canUndo)
        #expect(spy.performed.isEmpty)
    }

    @Test func invalidateOnlyRemovesTheMatchingRecord() {
        let undoManager = UndoManager()
        let (coordinator, spy) = makeCoordinator(undoManager: undoManager)
        let kept = record(file: "src/pages/index.astro", commit: "c1")
        let dropped = record(file: "src/pages/about.astro", commit: "c2")

        coordinator.registerApplied(kept)
        coordinator.registerApplied(dropped)
        coordinator.invalidate(editID: dropped.editID)

        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(spy.performed == [kept])
        #expect(!undoManager.canUndo)
    }

    @Test func invalidateAfterUndoFiredIsANoOp() {
        let undoManager = UndoManager()
        let (coordinator, spy) = makeCoordinator(undoManager: undoManager)
        let first = record(commit: "c1")
        let second = record(commit: "c2")

        coordinator.registerApplied(first)
        coordinator.registerApplied(second)
        undoManager.undo()  // consumes `second`

        // ⌘Z already popped `second`; the model's post-undo invalidate for it must not
        // disturb the remaining `first` entry.
        coordinator.invalidate(editID: second.editID)

        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(spy.performed == [second, first])
    }

    @Test func invalidateForUnknownEditIsANoOp() {
        let undoManager = UndoManager()
        let (coordinator, _) = makeCoordinator(undoManager: undoManager)

        coordinator.registerApplied(record())
        coordinator.invalidate(editID: UUID())

        #expect(undoManager.canUndo)
    }

    @Test func actionNameForFileWithoutDirectoryUsesTheWholeName() {
        #expect(EditUndoCoordinator.actionName(for: record(file: "astro.config.mjs")) == "Edit astro.config.mjs")
    }
}
