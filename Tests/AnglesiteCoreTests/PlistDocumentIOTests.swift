import Testing
import Foundation
@testable import AnglesiteCore

struct PlistDocumentIOTests {
    private func makeTempFile(named name: String = "Info.plist") throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("anglesite-plist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    @Test("load reads scalar dictionary plist entries")
    func loadScalarDictionary() throws {
        let url = try makeTempFile()
        let date = Date(timeIntervalSinceReferenceDate: 42)
        let plist: [String: Any] = [
            "Name": "Acme",
            "Enabled": true,
            "Count": 3,
            "Ratio": 1.5,
            "Created": date
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)

        let loaded = try PlistDocumentIO.load(url)

        #expect(loaded.entries.contains(.init(key: "Name", value: .string("Acme"))))
        #expect(loaded.entries.contains(.init(key: "Enabled", value: .bool(true))))
        #expect(loaded.entries.contains(.init(key: "Count", value: .integer(3))))
        #expect(loaded.entries.contains(.init(key: "Ratio", value: .double(1.5))))
        #expect(loaded.entries.contains(.init(key: "Created", value: .date(date))))
        #expect(loaded.modificationDate != nil)
    }

    @Test("save writes scalar dictionary plist entries")
    func saveScalarDictionary() throws {
        let url = try makeTempFile()
        try PlistDocumentIO.save([
            .init(key: "Name", value: .string("Acme")),
            .init(key: "Enabled", value: .bool(false)),
            .init(key: "Count", value: .integer(4))
        ], to: url)

        let loaded = try PlistDocumentIO.load(url)

        #expect(loaded.entries.contains(.init(key: "Name", value: .string("Acme"))))
        #expect(loaded.entries.contains(.init(key: "Enabled", value: .bool(false))))
        #expect(loaded.entries.contains(.init(key: "Count", value: .integer(4))))
    }

    @Test("save rejects blank and duplicate keys")
    func saveValidatesKeys() throws {
        let url = try makeTempFile()
        #expect(throws: PlistDocumentIO.PlistError.blankKey) {
            try PlistDocumentIO.save([.init(key: " ", value: .string(""))], to: url)
        }
        #expect(throws: PlistDocumentIO.PlistError.duplicateKey("Name")) {
            try PlistDocumentIO.save([
                .init(key: "Name", value: .string("A")),
                .init(key: "Name", value: .string("B"))
            ], to: url)
        }
    }

    @Test("load rejects non-dictionary plist roots")
    func loadRejectsNonDictionaryRoot() throws {
        let url = try makeTempFile()
        let data = try PropertyListSerialization.data(fromPropertyList: ["x", "y"], format: .xml, options: 0)
        try data.write(to: url)

        #expect(throws: PlistDocumentIO.PlistError.rootNotDictionary) {
            try PlistDocumentIO.load(url)
        }
    }
}
