import Testing
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import AnglesiteCore

/// Tests `DPoPKeyPair`'s proof construction (RFC 9449 §4.2) and persistence round-trip — the
/// piece `SiteIndieAuthClient`/`MicrosubClient` lean on for every DPoP-bound request.
@Suite
struct DPoPKeyPairTests {
    private func base64urlDecode(_ segment: String) -> Data {
        var base64 = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64) ?? Data()
    }

    private func jsonSegment(_ segment: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: base64urlDecode(segment))) as? [String: Any] ?? [:]
    }

    @Test("persistedRepresentation round-trips through init?(persistedRepresentation:)")
    func persistenceRoundTrips() throws {
        let original = DPoPKeyPair()
        let restored = DPoPKeyPair(persistedRepresentation: original.persistedRepresentation)
        #expect(restored != nil)
        #expect(restored?.persistedRepresentation == original.persistedRepresentation)
    }

    @Test("init?(persistedRepresentation:) rejects malformed bytes")
    func rejectsMalformedBytes() {
        #expect(DPoPKeyPair(persistedRepresentation: Data([0x01, 0x02, 0x03])) == nil)
    }

    #if canImport(CryptoKit)
    @Test("proof carries a well-formed header and htm/htu/jti/iat payload, no ath by default")
    func proofClaims() throws {
        let keyPair = DPoPKeyPair()
        let proof = try keyPair.proof(htm: "POST", htu: "https://owner.example/microsub")
        let segments = proof.split(separator: ".", omittingEmptySubsequences: false)
        #expect(segments.count == 3)

        let header = jsonSegment(String(segments[0]))
        #expect(header["typ"] as? String == "dpop+jwt")
        #expect(header["alg"] as? String == "ES256")
        let jwk = header["jwk"] as? [String: String]
        #expect(jwk?["kty"] == "EC")
        #expect(jwk?["crv"] == "P-256")
        #expect(jwk?["x"]?.isEmpty == false)
        #expect(jwk?["y"]?.isEmpty == false)

        let payload = jsonSegment(String(segments[1]))
        #expect(payload["htm"] as? String == "POST")
        #expect(payload["htu"] as? String == "https://owner.example/microsub")
        #expect((payload["jti"] as? String)?.isEmpty == false)
        #expect(payload["iat"] as? Int != nil)
        #expect(payload["ath"] == nil)
    }

    @Test("proof(accessToken:) carries the base64url(SHA-256(token)) ath claim")
    func proofAccessTokenHash() throws {
        let keyPair = DPoPKeyPair()
        let token = "example-access-token"
        let proof = try keyPair.proof(htm: "GET", htu: "https://owner.example/microsub", accessToken: token)
        let segments = proof.split(separator: ".", omittingEmptySubsequences: false)
        let payload = jsonSegment(String(segments[1]))

        let expectedAth = Data(SHA256.hash(data: Data(token.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(payload["ath"] as? String == expectedAth)
    }

    @Test("two proofs for the same request use distinct jti values")
    func jtiIsUnique() throws {
        let keyPair = DPoPKeyPair()
        let first = jsonSegment(String(try keyPair.proof(htm: "GET", htu: "https://owner.example/x").split(separator: ".")[1]))
        let second = jsonSegment(String(try keyPair.proof(htm: "GET", htu: "https://owner.example/x").split(separator: ".")[1]))
        #expect(first["jti"] as? String != second["jti"] as? String)
    }

    @Test("the proof's signature verifies against its own embedded public key")
    func signatureVerifiesAgainstEmbeddedKey() throws {
        let keyPair = DPoPKeyPair()
        let proof = try keyPair.proof(htm: "POST", htu: "https://owner.example/microsub")
        let segments = proof.split(separator: ".", omittingEmptySubsequences: false)
        let header = jsonSegment(String(segments[0]))
        let jwk = header["jwk"] as! [String: String]

        let x = base64urlDecode(jwk["x"]!)
        let y = base64urlDecode(jwk["y"]!)
        // Matches DPoPKeyPair.publicJWK's own extraction: X9.63 uncompressed point format.
        let publicKey = try P256.Signing.PublicKey(x963Representation: Data([0x04]) + x + y)

        let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
        let signatureBytes = base64urlDecode(String(segments[2]))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureBytes)
        #expect(publicKey.isValidSignature(signature, for: signingInput))
    }
    #endif
}
