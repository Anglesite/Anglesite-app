import Foundation
import AnglesiteSiteModel

/// Cheap, synchronous summary of a `.anglesite` package's identity and content-layout facts,
/// built for the Quick Look preview/thumbnail extensions (#621). Reads only the `Info.plist`
/// marker and file-layout counts — never parses content, never touches a dev server or container.
public struct PackagePreviewSummary: Sendable, Equatable {
    public let displayName: String
    public let createdDate: Date
    public let pageCount: Int
    /// One entry per subdirectory of `Source/src/content/`, ordered by directory name.
    public let collectionCounts: [CollectionCount]
    public let sourceLastModified: Date?
    /// Set only when `Config/quicklook-thumbnail.png` actually exists — no writer for this cache
    /// exists yet; this is the read-if-present path for a future feature.
    public let cachedThumbnailURL: URL?

    public struct CollectionCount: Sendable, Equatable {
        public let name: String
        public let count: Int

        public init(name: String, count: Int) {
            self.name = name
            self.count = count
        }
    }

    public init(
        displayName: String,
        createdDate: Date,
        pageCount: Int,
        collectionCounts: [CollectionCount],
        sourceLastModified: Date?,
        cachedThumbnailURL: URL?
    ) {
        self.displayName = displayName
        self.createdDate = createdDate
        self.pageCount = pageCount
        self.collectionCounts = collectionCounts
        self.sourceLastModified = sourceLastModified
        self.cachedThumbnailURL = cachedThumbnailURL
    }

    /// Directories skipped when scanning `Source/` for the most recent modification time —
    /// generated/vendored trees whose churn doesn't reflect the author's own edits.
    private static let modificationScanExclusions: Set<String> = ["node_modules", ".git", "dist"]

    /// Builds a summary from `package`. Throws `AnglesitePackage.PackageError` if the marker is
    /// missing or unreadable — callers treat that as "not a readable Anglesite site".
    public static func summarize(
        _ package: AnglesitePackage,
        fileManager: FileManager = .default
    ) throws -> PackagePreviewSummary {
        let marker = try package.readMarker(fileManager: fileManager)

        let pagesURL = package.sourceURL
            .appendingPathComponent("src", isDirectory: true)
            .appendingPathComponent("pages", isDirectory: true)
        let pageCount = (try? fileManager.contentsOfDirectory(atPath: pagesURL.path))?
            .filter { !$0.hasPrefix(".") }
            .count ?? 0

        let contentURL = package.sourceURL
            .appendingPathComponent("src", isDirectory: true)
            .appendingPathComponent("content", isDirectory: true)
        let collections = collectionCounts(under: contentURL, fileManager: fileManager)

        let lastModified = mostRecentModificationDate(under: package.sourceURL, fileManager: fileManager)

        var thumbnailURL: URL?
        if fileManager.fileExists(atPath: package.quickLookThumbnailURL.path) {
            thumbnailURL = package.quickLookThumbnailURL
        }

        return PackagePreviewSummary(
            displayName: marker.displayName,
            createdDate: marker.createdDate,
            pageCount: pageCount,
            collectionCounts: collections,
            sourceLastModified: lastModified,
            cachedThumbnailURL: thumbnailURL
        )
    }

    private static func collectionCounts(under contentURL: URL, fileManager: FileManager) -> [CollectionCount] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: contentURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        let directories = entries.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        return directories
            .map { url -> CollectionCount in
                let count = (try? fileManager.contentsOfDirectory(atPath: url.path))?
                    .filter { !$0.hasPrefix(".") }
                    .count ?? 0
                return CollectionCount(name: url.lastPathComponent, count: count)
            }
            .sorted { $0.name < $1.name }
    }

    private static func mostRecentModificationDate(under root: URL, fileManager: FileManager) -> Date? {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var mostRecent: Date?
        for case let url as URL in enumerator {
            if modificationScanExclusions.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory != true,
                  let modified = values.contentModificationDate
            else {
                continue
            }
            if mostRecent == nil || modified > mostRecent! {
                mostRecent = modified
            }
        }
        return mostRecent
    }
}
