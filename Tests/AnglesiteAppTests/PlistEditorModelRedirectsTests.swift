import Testing
import Foundation
@testable import AnglesiteAppCore
@testable import AnglesiteCore

@Suite("PlistEditorModel redirects (#530)")
@MainActor
struct PlistEditorModelRedirectsTests {
    private static let emptyPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict/></plist>
        """

    /// Builds a `PlistEditorModel` against a fresh temp `sourceDirectory` with a minimal
    /// `Info.plist` at `file.url` — `PlistEditorModel.load()` reads both the plist and (via this
    /// task) `redirects.json` from that same directory.
    private func makeModel() throws -> PlistEditorModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlistEditorModelRedirectsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plistURL = dir.appendingPathComponent("Info.plist")
        try Self.emptyPlist.write(to: plistURL, atomically: true, encoding: .utf8)
        let file = FileRef(url: plistURL, group: .metadata, name: "Info.plist")
        return PlistEditorModel(file: file, websiteTitle: "Test Site", sourceDirectory: dir)
    }

    @Test("load() populates redirectEntries from redirects.json, empty when absent")
    func loadPopulatesEmpty() async throws {
        let model = try makeModel()
        await model.load()
        #expect(model.redirectEntries.isEmpty)
        #expect(model.isRedirectsDirty == false)
    }

    @Test("isRedirectsDirty flips true after appending an entry, false after saveRedirects")
    func dirtyTrackingAndSave() async throws {
        let model = try makeModel()
        await model.load()
        model.redirectEntries.append(RedirectsStore.RedirectEntry(source: "/old", destination: "/new", code: .permanent))
        #expect(model.isRedirectsDirty == true)
        let saved = await model.saveRedirects()
        #expect(saved == true)
        #expect(model.isRedirectsDirty == false)
        #expect(try RedirectsStore(sourceDirectory: model.sourceDirectory).load() == model.redirectEntries)
    }

    @Test("saveRedirects surfaces a validation failure via redirectsError and leaves isRedirectsDirty true")
    func saveValidationFailureSurfacesError() async throws {
        let model = try makeModel()
        await model.load()
        model.redirectEntries.append(RedirectsStore.RedirectEntry(source: "/a", destination: "/a", code: .permanent))
        let saved = await model.saveRedirects()
        #expect(saved == false)
        #expect(model.redirectsError != nil)
        #expect(model.isRedirectsDirty == true)
    }
}
