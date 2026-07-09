import Testing
@testable import AnglesiteAppCore

@Suite("AnglesiteAppCore smoke")
struct SmokeTests {
    @Test("target compiles and links")
    func targetLinks() {
        #expect(Bool(true))
    }
}
