import Foundation
import Testing
@testable import AnglesiteCore

/// Unit tests for ``EditUndoCoordinator`` — the AnglesiteCore piece of #527 that turns each
/// applied edit into a window `UndoManager` record so Edit ▸ Undo (⌘Z) reverses it.
///
/// Every test drives a real Foundation `UndoManager` (no window needed): registration,
/// LIFO pops, selective + bulk invalidation, outcome-driven re-arming, and the no-redo
/// policy are all observable through `canUndo`/`canRedo`/`undoActionName` plus the injected
/// perform closure. ⌘Z pops the stack entry synchronously but resolves the revert in a
/// `Task`; tests await `pendingPerform` to observe the settled state.
@MainActor
struct EditUndoCoordinatorTests {
    private final class PerformSpy {
        var performed: [EditUndoCoordinator.Record] = []
        var outcome: EditUndoCoordinator.UndoOutcome = .undone
    }

    /// A run-loop-free `UndoManager`. With the default `groupsByEvent`, the implicit event
    /// group opens at the first registration and never closes (tests don't spin the run loop),
    /// so a single `undo()` would pop every registration at once and
    /// `removeAllActions(withTarget:)` couldn't clear the still-open group. Disabling it makes
    /// the coordinator's explicit per-record group the top-level group — the same shape
    /// production gets from one registration per main-run-loop turn. The production
    /// configuration (`groupsByEvent = true`) is exercised separately in
    /// ``sameRunLoopBurstBatchesUnderGroupsByEvent()``.
    private func makeUndoManager() -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return undoManager
    }

    private func makeCoordinator(undoManager: UndoManager?) -> (EditUndoCoordinator, PerformSpy) {
        let spy = PerformSpy()
        let coordinator = EditUndoCoordinator { record in
            spy.performed.append(record)
            return spy.outcome
        }
        coordinator.undoManager = undoManager
        return (coordinator, spy)
    }

    private func record(
        file: String = "src/pages/index.astro",
        commit: String = "abcd1234"
    ) -> EditUndoCoordinator.Record {
        EditUndoCoordinator.Record(file: file, commit: commit)
    }

    @Test func registeredEditIsUndoableAndUndoPerformsIt() async {
        let undoManager = makeUndoManager()
        let (coordinator, spy) = makeCoordinator(undoManager: undoManager)
        let record = record()

        #expect(!undoManager.canUndo)
        coordinator.registerApplied(record)
        #expect(undoManager.canUndo)

        undoManager.undo()
        await coordinator.pendingPerform?.value

        #expect(spy.performed == [record])
        #expect(!undoManager.canUndo)
    }

    @Test func actionNameCarriesTheEditedFilename() {
        let undoManager = makeUndoManager()
        let (coordinator, _) = makeCoordinator(undoManager: undoManager)

        coordinator.registerApplied(record(file: "src/pages/about.astro"))

        #expect(undoManager.undoActionName == "Edit about.astro")
    }

    @Test func undoDoesNotRegisterARedo() async {
        let undoManager = makeUndoManager()
        let (coordinator, _) = makeCoordinator(undoManager: undoManager)

        coordinator.registerApplied(record())
        undoManager.undo()
        await coordinator.pendingPerform?.value

        // Reverse-apply is a git revert via the plugin's `undo_edit`; there is no re-apply
        // primitive, so the coordinator must not put anything on the redo stack.
        #expect(!undoManager.canRedo)
    }

    @Test func multipleEditsUndoInLIFOOrder() async {
        let undoManager = makeUndoManager()
        let (coordinator, spy) = makeCoordinator(undoManager: undoManager)
        let first = record(file: "src/pages/index.astro", commit: "c1")
        let second = record(file: "src/pages/about.astro", commit: "c2")

        coordinator.registerApplied(first)
        coordinator.registerApplied(second)

        undoManager.undo()
        await coordinator.pendingPerform?.value
        #expect(spy.performed == [second])
        undoManager.undo()
        await coordinator.pendingPerform?.value
        #expect(spy.performed == [second, first])
    }

    @Test func registeringWithoutAnUndoManagerIsANoOp() {
        let (coordinator, spy) = makeCoordinator(undoManager: nil)

        coordinator.registerApplied(record())

        #expect(spy.performed.isEmpty)
    }

    @Test func retryableOutcomeReArmsTheRecord() async {
        let undoManager = makeUndoManager()
        let (coordinator, spy) = makeCoordinator(undoManager: undoManager)
        let record = record(file: "src/pages/index.astro", commit: "c1")
        spy.outcome = .retryable

        coordinator.registerApplied(record)
        undoManager.undo()
        await coordinator.pendingPerform?.value

        // The stack entry was popped synchronously, but the revert failed/conflicted —
        // the coordinator re-registers so ⌘Z can retry, and nothing lands on redo.
        #expect(spy.performed == [record])
        #expect(undoManager.canUndo)
        #expect(!undoManager.canRedo)
        #expect(undoManager.undoActionName == "Edit index.astro")

        // The retry succeeds this time and the record is spent.
        spy.outcome = .undone
        undoManager.undo()
        await coordinator.pendingPerform?.value
        #expect(spy.performed == [record, record])
        #expect(!undoManager.canUndo)
    }

    @Test func staleOutcomeDoesNotReArm() async {
        let undoManager = makeUndoManager()
        let (coordinator, spy) = makeCoordinator(undoManager: undoManager)
        spy.outcome = .stale

        coordinator.registerApplied(record())
        undoManager.undo()
        await coordinator.pendingPerform?.value

        // The record no longer maps to an undoable edit (row gone / already undone) —
        // consumed without re-arming.
        #expect(spy.performed.count == 1)
        #expect(!undoManager.canUndo)
    }

    @Test func reArmedRecordCanBeInvalidatedOutOfBand() async {
        let undoManager = makeUndoManager()
        let (coordinator, spy) = makeCoordinator(undoManager: undoManager)
        let record = record(commit: "c1")
        spy.outcome = .retryable

        coordinator.registerApplied(record)
        undoManager.undo()
        await coordinator.pendingPerform?.value
        #expect(undoManager.canUndo)  // re-armed

        // The conflict sheet's "Undo anyway" (or the row button) eventually reverts it via
        // another path — the success path invalidates the re-armed entry by commit.
        coordinator.invalidate(commit: "c1")
        #expect(!undoManager.canUndo)
    }

    @Test func invalidateRemovesTheRecordFromTheUndoStack() {
        let undoManager = makeUndoManager()
        let (coordinator, spy) = makeCoordinator(undoManager: undoManager)
        let record = record()

        coordinator.registerApplied(record)
        coordinator.invalidate(commit: record.commit)

        #expect(!undoManager.canUndo)
        #expect(spy.performed.isEmpty)
    }

    @Test func invalidateOnlyRemovesTheMatchingRecord() async {
        let undoManager = makeUndoManager()
        let (coordinator, spy) = makeCoordinator(undoManager: undoManager)
        let kept = record(file: "src/pages/index.astro", commit: "c1")
        let dropped = record(file: "src/pages/about.astro", commit: "c2")

        coordinator.registerApplied(kept)
        coordinator.registerApplied(dropped)
        coordinator.invalidate(commit: dropped.commit)

        #expect(undoManager.canUndo)
        undoManager.undo()
        await coordinator.pendingPerform?.value
        #expect(spy.performed == [kept])
        #expect(!undoManager.canUndo)
    }

    @Test func invalidateAfterUndoFiredIsANoOp() async {
        let undoManager = makeUndoManager()
        let (coordinator, spy) = makeCoordinator(undoManager: undoManager)
        let first = record(commit: "c1")
        let second = record(commit: "c2")

        coordinator.registerApplied(first)
        coordinator.registerApplied(second)
        undoManager.undo()  // consumes `second`
        await coordinator.pendingPerform?.value

        // ⌘Z already popped `second` (and its `.undone` outcome spent it); the model's
        // post-undo invalidate for it must not disturb the remaining `first` entry.
        coordinator.invalidate(commit: second.commit)

        #expect(undoManager.canUndo)
        undoManager.undo()
        await coordinator.pendingPerform?.value
        #expect(spy.performed == [second, first])
    }

    @Test func invalidateForUnknownCommitIsANoOp() {
        let undoManager = makeUndoManager()
        let (coordinator, _) = makeCoordinator(undoManager: undoManager)

        coordinator.registerApplied(record(commit: "c1"))
        coordinator.invalidate(commit: "not-registered")

        #expect(undoManager.canUndo)
    }

    @Test func invalidateAllDropsEveryPendingRecord() {
        let undoManager = makeUndoManager()
        let (coordinator, spy) = makeCoordinator(undoManager: undoManager)

        coordinator.registerApplied(record(commit: "c1"))
        coordinator.registerApplied(record(file: "src/pages/about.astro", commit: "c2"))
        coordinator.invalidateAll()

        #expect(!undoManager.canUndo)
        #expect(spy.performed.isEmpty)
    }

    /// The production configuration: `groupsByEvent = true` with no run loop cycling between
    /// registrations — the worst case where two edits land in the same main-run-loop turn.
    /// The coordinator's explicit groups nest inside the still-open event group, so one ⌘Z
    /// batches both reverts (well-defined, stack fully consumed, nothing on redo) rather than
    /// corrupting the stack. In the app, every real apply arrives in its own run-loop turn
    /// (each is a separate MCP-reply hop), which restores the one-edit-per-⌘Z behavior — that
    /// cross-turn split needs a cycling run loop, so it isn't unit-testable here; it was
    /// verified against a live `RunLoop` (see PR #544).
    @Test func sameRunLoopBurstBatchesUnderGroupsByEvent() async {
        let undoManager = UndoManager()  // groupsByEvent stays true, as in the app
        let (coordinator, spy) = makeCoordinator(undoManager: undoManager)
        let first = record(commit: "c1")
        let second = record(file: "src/pages/about.astro", commit: "c2")

        coordinator.registerApplied(first)
        coordinator.registerApplied(second)

        undoManager.undo()
        // The one undo fires both handlers synchronously; each resolves in its own Task.
        for _ in 0..<1000 where spy.performed.count < 2 { await Task.yield() }

        // Both records revert (handler order within the group is LIFO, but the two Tasks'
        // completion order is not contractual — assert membership, not order).
        #expect(Set(spy.performed.map(\.commit)) == ["c1", "c2"])
        #expect(spy.performed.count == 2)
        #expect(!undoManager.canUndo)
        #expect(!undoManager.canRedo)
    }

    @Test func actionNameForFileWithoutDirectoryUsesTheWholeName() {
        #expect(EditUndoCoordinator.actionName(for: record(file: "astro.config.mjs")) == "Edit astro.config.mjs")
    }
}
