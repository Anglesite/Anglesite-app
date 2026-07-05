import Testing
import Foundation
@testable import AnglesiteCore

/// Tests for the user-facing copy of `TokenVerifyError`. The verifier behavior itself lives in
/// `CloudflareAPITokenVerifierTests` (the native, Node-free conformer).
struct CloudflareTokenVerifierTests {
    @Test("Invalid-token error names the Anglesite token")
    func invalidTokenCopyNamesTemplate() {
        #expect(TokenVerifyError.invalidToken.userMessage.contains("Anglesite"))
    }

    @Test("Network error tells the user to check their connection")
    func networkCopyMentionsConnection() {
        #expect(TokenVerifyError.network.userMessage.localizedCaseInsensitiveContains("connection"))
    }
}
