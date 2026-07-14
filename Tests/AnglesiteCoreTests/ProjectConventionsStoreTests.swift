import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ProjectConventionsStore")
struct ProjectConventionsStoreTests {
    private func makeConfigDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("conventions-store-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("load returns nil when no file exists yet")
    func loadReturnsNilWhenMissing() async {
        let store = ProjectConventionsStore(configDirectory: makeConfigDirectory())
        #expect(await store.load() == nil)
    }

    @Test("save then load round-trips a value, including overrides")
    func saveThenLoadRoundTrips() async {
        let store = ProjectConventionsStore(configDirectory: makeConfigDirectory())
        var conventions = ProjectConventions.empty
        conventions.apply(.brandTerms(["Anglesite"]))

        await store.save(conventions)
        let loaded = await store.load()

        #expect(loaded?.writing.brandTerms.value == ["Anglesite"])
        #expect(loaded?.writing.brandTerms.isOverridden == true)
    }

    @Test("save creates the config directory if it doesn't exist yet")
    func saveCreatesConfigDirectory() async {
        let configDirectory = makeConfigDirectory()
        let store = ProjectConventionsStore(configDirectory: configDirectory)

        await store.save(.empty)

        #expect(FileManager.default.fileExists(atPath: configDirectory.appendingPathComponent("conventions.json").path))
    }
}
