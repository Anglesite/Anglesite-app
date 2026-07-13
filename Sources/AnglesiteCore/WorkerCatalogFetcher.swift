import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum WorkerCatalogFetchError: Error, Sendable, Equatable {
    case fetchFailed(String)
}

/// Fetches, parses, and disk-caches the `@dwk/workers` catalog manifest (`catalog.json`).
/// Network or parse failures degrade to the last successfully cached copy, then to an empty
/// catalog — the Workers Settings tab and deploy composition must never block or crash on a
/// catalog fetch failure (design doc §3).
///
/// - Important: `catalogURL` has no in-app default. As of this writing `@dwk/workers` has not
///   yet published `catalog.json` — callers must supply the real manifest URL once the monorepo
///   publishes one.
public actor WorkerCatalogFetcher {
    private let catalogURL: URL
    private let cacheURL: URL
    private let session: URLSession
    private let fileManager: FileManager

    public init(
        catalogURL: URL,
        cacheURL: URL = WorkerCatalogFetcher.defaultCacheURL(),
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.catalogURL = catalogURL
        self.cacheURL = cacheURL
        self.session = session
        self.fileManager = fileManager
    }

    /// Fetches the latest catalog and caches the raw manifest bytes to disk on success. On any
    /// failure (network error, non-2xx response, malformed JSON), falls back to the last cached
    /// catalog; if there is no cache either, returns an empty catalog. Never throws.
    public func catalog() async -> [WorkerDescriptor] {
        if let fresh = try? await fetchAndCache() {
            return fresh
        }
        return (try? Self.readCache(cacheURL)) ?? []
    }

    private func fetchAndCache() async throws -> [WorkerDescriptor] {
        let (data, response) = try await session.data(from: catalogURL)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw WorkerCatalogFetchError.fetchFailed("bad response from \(catalogURL)")
        }
        let descriptors = try WorkerCatalogReader.parse(data)
        try Self.writeCache(data, to: cacheURL, fileManager: fileManager)
        return descriptors
    }

    private static func readCache(_ url: URL) throws -> [WorkerDescriptor] {
        let data = try Data(contentsOf: url)
        return try WorkerCatalogReader.parse(data)
    }

    private static func writeCache(_ data: Data, to url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    /// `~/Library/Application Support/Anglesite/worker-catalog-cache.json` — mirrors
    /// `SiteStore`'s `defaultPersistenceURL` convention (`SiteStore.swift:323-333`).
    public static func defaultCacheURL(fileManager: FileManager = .default) -> URL {
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Anglesite", isDirectory: true)
            .appendingPathComponent("worker-catalog-cache.json")
    }
}
