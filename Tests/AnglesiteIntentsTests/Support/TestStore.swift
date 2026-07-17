import Foundation
@testable import AnglesiteCore

/// Builds a throwaway `SiteStore` populated with the given sites. Each call uses a unique
/// persistence URL under `NSTemporaryDirectory()` so parallel test suites don't collide.
enum TestStore {
    static func with(_ sites: [SiteStore.Site]) async throws -> SiteStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anglesite-intents-test-\(UUID().uuidString).json")
        // `load()` prunes any site whose `packageURL` doesn't exist on disk (#749/#776) — create
        // each fixture's package directory so seeded sites survive the reload every
        // `SiteEntityQuery` call triggers (#771), matching the invariant a real package satisfies.
        for site in sites {
            try FileManager.default.createDirectory(at: site.packageURL, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(sites).write(to: url)
        let store = SiteStore(persistenceURL: url)
        try await store.load()
        return store
    }

    static func site(id: String, name: String, path: String? = nil) -> SiteStore.Site {
        SiteStore.Site(
            id: id,
            name: name,
            packageURL: URL(fileURLWithPath: (path ?? "/tmp/\(name)") + ".anglesite", isDirectory: true),
            isValid: true,
            missingSentinels: []
        )
    }
}
