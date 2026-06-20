import Testing
import Foundation
@testable import AnglesiteCore

struct EditorKindTests {
    @Test("v1 routes every file group to the text editor")
    func everythingIsText() {
        for group in FileGroup.allCases {
            let ref = FileRef(url: URL(fileURLWithPath: "/tmp/x"), group: group, name: "x")
            #expect(EditorKind.resolve(for: ref) == .text)
        }
    }
}
