import Testing
@testable import AnglesiteCore

@Suite("SiteOperations cancel dialog")
struct SiteOperationsDialogTests {
    @Test("canceled dialog names the operation and site")
    func canceled() {
        #expect(SiteOperations.canceledDialog(operation: "deploy", siteName: "My Site") == "Canceled the deploy of My Site.")
        #expect(SiteOperations.canceledDialog(operation: "backup", siteName: "Blog") == "Canceled the backup of Blog.")
    }
}
