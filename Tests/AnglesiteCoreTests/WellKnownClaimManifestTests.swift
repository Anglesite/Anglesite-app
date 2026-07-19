import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WellKnownClaimManifest contract types")
struct WellKnownClaimManifestTests {

    @Test("RuntimeOwnedPathClaim round-trips through JSON")
    func claimRoundTrips() throws {
        let claim = RuntimeOwnedPathClaim(
            id: "acme-managed-tls",
            owner: "cloudflare-managed-tls",
            path: "acme-challenge/",
            match: .prefix,
            schemes: [.http],
            port: 80,
            capability: "RFC 8555 managed-TLS ownership",
            specificationURL: URL(string: "https://www.rfc-editor.org/rfc/rfc8555.html"))
        let data = try JSONEncoder().encode(claim)
        let decoded = try JSONDecoder().decode(RuntimeOwnedPathClaim.self, from: data)
        #expect(decoded == claim)
    }

    @Test("empty WellKnownClaimManifest round-trips")
    func emptyManifestRoundTrips() throws {
        let manifest = WellKnownClaimManifest()
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(WellKnownClaimManifest.self, from: data)
        #expect(decoded == manifest)
        #expect(decoded.entries.isEmpty)
    }

    @Test("WellKnownClaimManifest with entries round-trips")
    func populatedManifestRoundTrips() throws {
        let manifest = WellKnownClaimManifest(entries: [
            .init(id: "security-txt", path: "security.txt", match: .exact, owner: "generator:security-txt"),
            .init(id: "acme", path: "acme-challenge/", match: .prefix, owner: "cloudflare-managed-tls")
        ])
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(WellKnownClaimManifest.self, from: data)
        #expect(decoded == manifest)
    }

    @Test("WellKnownBuildSeamResult parses a valid JSON blob")
    func seamResultParsesValidJSON() {
        let json = #"{"observedArtifacts":["security.txt"],"findings":[{"path":"security.txt","message":"ok"}]}"#
        let result = WellKnownBuildSeamResult.parsing(json)
        #expect(result.observedArtifacts == ["security.txt"])
        #expect(result.findings == [.init(path: "security.txt", message: "ok")])
    }

    @Test("WellKnownBuildSeamResult degrades to empty on malformed JSON")
    func seamResultDegradesOnMalformedJSON() {
        let result = WellKnownBuildSeamResult.parsing("not valid json")
        #expect(result == WellKnownBuildSeamResult())
    }

    @Test("WellKnownBuildSeamResult degrades to empty on an empty blob")
    func seamResultDegradesOnEmptyBlob() {
        let result = WellKnownBuildSeamResult.parsing("")
        #expect(result == WellKnownBuildSeamResult())
    }
}
