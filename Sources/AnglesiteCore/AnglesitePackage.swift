import Foundation

/// A `.anglesite` package on disk: a Finder-opaque directory (UTI `dev.anglesite.site`,
/// `LSTypeIsPackage`) that wraps a git-tracked `Source/` Astro project, an app-owned `Config/`
/// directory, and an `Info.plist` marker carrying a stable site UUID + a format version.
///
/// This is the single source of truth for the package's internal layout. Recents discovery,
/// scaffold/deploy working directories, and the per-site config store all resolve paths through
/// here so the layout lives in exactly one file (spec §1).
public struct AnglesitePackage: Sendable, Equatable {
    /// Filename extension and package UTI suffix.
    public static let packageExtension = "anglesite"

    /// Current on-disk format. Bump when the layout changes in a way older builds can't safely
    /// write; `Marker.formatVersion` is compared against this on open (see `compatibility(for:)`).
    public static let currentFormatVersion = 1

    /// The package directory (`…/Name.anglesite`).
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    // MARK: - Layout

    public var infoPlistURL: URL { url.appendingPathComponent("Info.plist") }
    public var sourceURL: URL { url.appendingPathComponent("Source", isDirectory: true) }
    public var configURL: URL { url.appendingPathComponent("Config", isDirectory: true) }

    // MARK: - Marker

    /// The `Info.plist` marker: stable identity + format version + provenance. Encoded with
    /// `PropertyListEncoder`, so `createdDate` is a native plist date and `siteID` a plist string.
    public struct Marker: Sendable, Codable, Equatable {
        public var formatVersion: Int
        public var siteID: UUID
        public var displayName: String
        public var createdDate: Date

        public init(
            formatVersion: Int = AnglesitePackage.currentFormatVersion,
            siteID: UUID = UUID(),
            displayName: String,
            createdDate: Date = Date()
        ) {
            self.formatVersion = formatVersion
            self.siteID = siteID
            self.displayName = displayName
            // XML property-list <date> values have whole-second granularity, so we truncate to
            // a second boundary here. This keeps an in-memory Marker equal to the one decoded
            // back from Info.plist (the writeMarker→readMarker round-trip contract).
            self.createdDate = Date(timeIntervalSinceReferenceDate:
                floor(createdDate.timeIntervalSinceReferenceDate))
        }

        private enum CodingKeys: String, CodingKey {
            case formatVersion = "AnglesiteFormatVersion"
            case siteID = "AnglesiteSiteID"
            case displayName = "AnglesiteDisplayName"
            case createdDate = "AnglesiteCreatedDate"
        }
    }

    public enum PackageError: Error, Equatable, Sendable {
        case markerMissing(URL)
        case markerUnreadable(URL)
    }

    /// Forward-compatibility verdict for an opened package's marker.
    public enum Compatibility: Sendable, Equatable {
        /// Same format the app writes — fully editable.
        case current
        /// Written by a newer build than this one. Open read-only and prompt to upgrade rather
        /// than silently rewriting a format we don't understand (spec §9).
        case readOnlyTooNew
    }

    public static func compatibility(for marker: Marker) -> Compatibility {
        marker.formatVersion > currentFormatVersion ? .readOnlyTooNew : .current
    }

    /// Reads and decodes the `Info.plist` marker. (Error cases handled in Task 2.)
    public func readMarker(fileManager: FileManager = .default) throws -> Marker {
        guard fileManager.fileExists(atPath: infoPlistURL.path) else {
            throw PackageError.markerMissing(infoPlistURL)
        }
        do {
            let data = try Data(contentsOf: infoPlistURL)
            return try PropertyListDecoder().decode(Marker.self, from: data)
        } catch {
            throw PackageError.markerUnreadable(infoPlistURL)
        }
    }

    /// Writes the marker to `Info.plist` (XML plist, atomic), creating the package dir if needed.
    public func writeMarker(_ marker: Marker, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(marker)
        try data.write(to: infoPlistURL, options: [.atomic])
    }

    // MARK: - Creation

    /// Creates an empty package skeleton: the package dir, `Source/`, `Config/`, and a freshly
    /// stamped `Info.plist`. Does **not** scaffold the Astro project — that runs later with cwd =
    /// `sourceURL` (P2). Returns the package and its new marker.
    @discardableResult
    public static func createSkeleton(
        at url: URL,
        displayName: String,
        fileManager: FileManager = .default
    ) throws -> (AnglesitePackage, Marker) {
        let pkg = AnglesitePackage(url: url)
        try fileManager.createDirectory(at: pkg.sourceURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: pkg.configURL, withIntermediateDirectories: true)
        let marker = Marker(displayName: displayName)
        try pkg.writeMarker(marker, fileManager: fileManager)
        return (pkg, marker)
    }

    // MARK: - Detection & validation

    /// `true` when `url` is a `.anglesite` directory carrying a readable marker.
    public static func isPackage(at url: URL, fileManager: FileManager = .default) -> Bool {
        guard url.pathExtension == packageExtension else { return false }
        return (try? AnglesitePackage(url: url).readMarker(fileManager: fileManager)) != nil
    }

    /// Validates the `Source/` tree against the Anglesite project sentinels.
    public func sourceValidation(fileManager: FileManager = .default) -> ProjectValidator.Result {
        ProjectValidator.validate(sourceURL, fileManager: fileManager)
    }
}
