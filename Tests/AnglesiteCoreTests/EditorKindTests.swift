import Testing
import Foundation
@testable import AnglesiteCore

struct EditorKindTests {
    @Test("metadata plist files route to the plist editor")
    func metadataPlistUsesPlistEditor() {
        let ref = FileRef(url: URL(fileURLWithPath: "/tmp/Info.plist"), group: .metadata, name: "Info.plist")
        #expect(EditorKind.resolve(for: ref) == .plist)
    }

    @Test("non-metadata plist files remain text editable")
    func sourcePlistUsesTextEditor() {
        let ref = FileRef(url: URL(fileURLWithPath: "/tmp/Config.plist"), group: .components, name: "Config.plist")
        #expect(EditorKind.resolve(for: ref) == .text)
    }

    @Test("non-plist files route to the text editor")
    func nonPlistFilesAreText() {
        for group in FileGroup.allCases {
            let ref = FileRef(url: URL(fileURLWithPath: "/tmp/x"), group: group, name: "x")
            #expect(EditorKind.resolve(for: ref) == .text)
        }
    }
}
