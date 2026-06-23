import Testing
import Foundation
@testable import AnglesiteCore

struct SessionTokenTests {
    @Test("mint produces a 64-char hex string")
    func mintFormat() {
        let t = SessionToken.mint()
        #expect(t.value.count == 64)
        #expect(t.value.allSatisfy { $0.isHexDigit })
    }

    @Test("two mints differ")
    func mintUnique() {
        #expect(SessionToken.mint() != SessionToken.mint())
    }

    @Test("description never leaks the value")
    func redactedDescription() {
        let t = SessionToken(value: "deadbeef")
        #expect(!"\(t)".contains("deadbeef"))
        #expect("\(t)".contains("SessionToken"))
    }
}
