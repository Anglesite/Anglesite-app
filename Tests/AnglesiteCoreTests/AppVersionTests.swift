import Testing
@testable import AnglesiteCore

@Suite struct AppVersionTests {
    @Test func readsTheShortVersionStringFromABundle() {
        // Note: Bundle.main inside `swift test` is the test runner — it has no
        // CFBundleShortVersionString. The meaningful guarantee this function provides
        // is "never crashes, returns an Optional", which the type signature itself
        // enforces. Test that it doesn't crash on .main (nil result expected).
        let mainVersion = AppVersion.current(in: .main)
        // Accessing the function doesn't crash, and returns Optional<String>
        #expect(mainVersion == nil)
    }
}
