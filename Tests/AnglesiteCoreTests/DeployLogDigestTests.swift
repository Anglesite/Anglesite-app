import Testing
@testable import AnglesiteCore

@Suite struct DeployLogDigestTests {
    @Test func dropsBuildNoiseKeepsError() {
        let raw = """
        > astro build
        npm run build
        vite v5.0 building for production...
        ✓ 42 modules transformed
        Publishing to Cloudflare...
        ✘ [ERROR] Could not resolve "./missing"
        """
        let digest = DeployLogDigest.extract(from: raw)
        #expect(digest.contains("Could not resolve"))
        #expect(digest.contains("Publishing to Cloudflare"))
        #expect(!digest.contains("astro build"))
        #expect(!digest.contains("npm run build"))
        #expect(!digest.contains("modules transformed"))
    }

    @Test func emptyInputReturnsEmpty() {
        #expect(DeployLogDigest.extract(from: "   \n  ").isEmpty)
    }

    @Test func capsToTail() {
        let long = String(repeating: "x", count: DeployLogDigest.maxCharacters + 500)
        let digest = DeployLogDigest.extract(from: long)
        #expect(digest.count == DeployLogDigest.maxCharacters)
        #expect(digest == String(long.suffix(DeployLogDigest.maxCharacters)))
    }

    @Test func keepsWranglerURLAndVersionLines() {
        let raw = """
        > astro build
        > https://my-worker.username.workers.dev
        > 1.2.3 deployed
        > {"success":true}
        ✘ [ERROR] deploy failed
        """
        let digest = DeployLogDigest.extract(from: raw)
        #expect(!digest.contains("astro build"))
        #expect(digest.contains("https://my-worker.username.workers.dev"))
        #expect(digest.contains("1.2.3 deployed"))
        #expect(digest.contains("{\"success\":true}"))
    }
}
