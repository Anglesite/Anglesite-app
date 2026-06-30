import Testing
import Foundation
import Observation
@testable import AnglesiteCore

private final class ObservationInvalidationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidated
    }

    func markInvalidated() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }
}

@MainActor
@Observable
private final class SessionBackedObservationProbe {
    var text = "saved"
    private var session = EditableFileSession(savedContents: "saved")

    var savedText: String { session.savedContents }
    var conflictDiskContents: String? {
        get { session.conflictDiskContents }
        set { session.conflictDiskContents = newValue }
    }
    var isDirty: Bool { text != savedText }

    func adoptSavedText(_ text: String) {
        session = EditableFileSession(savedContents: text)
    }
}

struct EditableFileSessionTests {
    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("editable-session-\(UUID().uuidString).txt")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func writeExternally(_ contents: String, to url: URL, after date: Date?) throws {
        let newer = (date ?? Date()).addingTimeInterval(2)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: newer], ofItemAtPath: url.path)
    }

    @Test("clean save updates saved contents and clears conflicts")
    func cleanSaveUpdatesSavedState() async throws {
        let url = try tempFile("old")
        defer { try? FileManager.default.removeItem(at: url) }
        var session = EditableFileSession()

        let loaded = try await session.load(from: url)
        #expect(loaded == "old")
        session.conflictDiskContents = "other"

        try await session.save("new", to: url)

        #expect(try String(contentsOf: url, encoding: .utf8) == "new")
        #expect(session.savedContents == "new")
        #expect(session.lastModified != nil)
        #expect(session.conflictDiskContents == nil)
    }

    @Test("clean external write is reloadable and updates saved contents")
    func reloadableExternalChangeUpdatesSavedState() async throws {
        let url = try tempFile("a")
        defer { try? FileManager.default.removeItem(at: url) }
        var session = EditableFileSession()
        _ = try await session.load(from: url)

        try writeExternally("b", to: url, after: session.lastModified)
        let change = await session.externalChange(at: url, bufferIsDirty: false)

        #expect(change == .reloadable("b"))
        #expect(session.savedContents == "b")
        #expect(session.conflictDiskContents == nil)
    }

    @Test("dirty external write records a conflict without replacing saved contents")
    func dirtyExternalChangeRecordsConflict() async throws {
        let url = try tempFile("a")
        defer { try? FileManager.default.removeItem(at: url) }
        var session = EditableFileSession()
        _ = try await session.load(from: url)

        try writeExternally("b", to: url, after: session.lastModified)
        let change = await session.externalChange(at: url, bufferIsDirty: true)

        #expect(change == .conflict("b"))
        #expect(session.savedContents == "a")
        #expect(session.conflictDiskContents == "b")
    }

    @Test("keep and reload resolve dirty conflicts explicitly")
    func keepAndReloadResolveConflicts() async throws {
        let url = try tempFile("a")
        defer { try? FileManager.default.removeItem(at: url) }
        var session = EditableFileSession()
        _ = try await session.load(from: url)

        try writeExternally("b", to: url, after: session.lastModified)
        #expect(await session.canFlushBeforeLeaving(file: url, bufferIsDirty: true) == false)
        #expect(session.conflictDiskContents == "b")

        session.keepMyChanges()
        #expect(session.conflictDiskContents == nil)
        #expect(session.savedContents == "a")

        _ = await session.externalChange(at: url, bufferIsDirty: true)
        let reloaded = await session.reloadFromConflict(file: url)

        #expect(reloaded == "b")
        #expect(session.savedContents == "b")
        #expect(session.conflictDiskContents == nil)
    }

    @MainActor
    @Test("session-backed computed properties invalidate Observation tracking")
    func sessionBackedComputedPropertiesInvalidateObservationTracking() {
        let model = SessionBackedObservationProbe()
        let conflictInvalidated = ObservationInvalidationFlag()
        withObservationTracking {
            _ = model.conflictDiskContents
        } onChange: {
            conflictInvalidated.markInvalidated()
        }

        model.conflictDiskContents = "disk"

        #expect(conflictInvalidated.value)
        #expect(model.conflictDiskContents == "disk")

        let dirtyInvalidated = ObservationInvalidationFlag()
        withObservationTracking {
            _ = model.isDirty
        } onChange: {
            dirtyInvalidated.markInvalidated()
        }

        model.adoptSavedText("new saved")

        #expect(dirtyInvalidated.value)
        #expect(model.isDirty)
    }
}
