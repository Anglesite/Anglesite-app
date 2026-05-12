import Foundation

/// Primes (and exposes) a pre-populated npm cache so sites can `npm install` without a cold
/// network fetch on first launch.
///
/// `scripts/vendor-npm-cache.sh` builds `Resources/npm-cache/cache.tar` at build time — a tarball
/// of an npm cache directory pre-filled by installing the bundled plugin's (and template's)
/// dependencies — plus a `version.txt` stamping which plugin/template revision it was built from.
/// The Xcode build copies `Resources/npm-cache/` into the app bundle. On launch, `prime()` extracts
/// that tarball into `~/Library/Application Support/Anglesite/npm-cache/` (once; re-extracts only
/// when the bundled `version.txt` changes), and `npmInstallArguments()` hands callers the
/// `install --prefer-offline --cache <path>` flags that point npm at it.
///
/// Shipping a *tarball* (one file) rather than the loose cache directory keeps the .app bundle a
/// single sealed blob — thousands of tiny cache files would balloon codesign/notarization time.
public struct NodeModulesCache: Sendable {
    /// Extracts `archive` so its contents land directly inside `destinationDirectory`
    /// (which already exists and is empty). Default implementation shells out to `/usr/bin/tar`.
    public typealias Extractor = @Sendable (_ archive: URL, _ destinationDirectory: URL) async throws -> Void

    /// A bundled cache archive and the plugin/template revision it was built from.
    public struct BundledArchive: Sendable, Equatable {
        public let url: URL
        public let version: String
        public init(url: URL, version: String) {
            self.url = url
            self.version = version
        }
    }

    public enum PrimeOutcome: Sendable, Equatable {
        /// No `npm-cache/cache.tar` in the bundle — e.g. running from `swift test`, or a build
        /// where `vendor-npm-cache.sh` was skipped. Sites just `npm install` against the network.
        case noBundledArchive
        /// The on-disk cache already matches the bundled version; nothing to do.
        case upToDate(version: String)
        /// The cache was (re-)extracted from the bundled archive.
        case extracted(version: String)
    }

    public enum CacheError: Error, Sendable, Equatable {
        case extractionFailed(exitCode: Int32, stderr: String)
    }

    public let bundledArchive: BundledArchive?
    /// Base Application Support directory (the `Anglesite/` subdir is appended internally).
    public let applicationSupportURL: URL
    private let extract: Extractor

    public init(bundledArchive: BundledArchive?, applicationSupportURL: URL, extract: @escaping Extractor) {
        self.bundledArchive = bundledArchive
        self.applicationSupportURL = applicationSupportURL
        self.extract = extract
    }

    /// App-wide instance: bundled archive resolved from `Bundle.main`, cache under the user's
    /// Application Support, `/usr/bin/tar` extraction via `ProcessSupervisor.shared`.
    public static let shared = NodeModulesCache(
        bundledArchive: resolveBundledArchive(in: .main),
        applicationSupportURL: defaultApplicationSupportURL(),
        extract: makeTarExtractor()
    )

    // MARK: Locations

    private var anglesiteSupportURL: URL {
        applicationSupportURL.appendingPathComponent("Anglesite", isDirectory: true)
    }

    /// Where the extracted npm cache lives. Pass this to `npm --cache`.
    public var npmCacheURL: URL {
        anglesiteSupportURL.appendingPathComponent("npm-cache", isDirectory: true)
    }

    /// Records which bundled `version` produced the current `npmCacheURL` contents.
    public var versionStampURL: URL {
        anglesiteSupportURL.appendingPathComponent("npm-cache.version")
    }

    // MARK: Priming

    /// Ensures `npmCacheURL` reflects the bundled archive. Idempotent: a no-op when the on-disk
    /// stamp matches the bundled version *and* the cache directory still exists; otherwise it
    /// wipes and re-extracts. Returns what it did. Throws only on extraction/filesystem failure.
    @discardableResult
    public func prime() async throws -> PrimeOutcome {
        guard let bundled = bundledArchive else { return .noBundledArchive }
        let fm = FileManager.default

        let currentStamp = (try? String(contentsOf: versionStampURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if currentStamp == bundled.version, fm.fileExists(atPath: npmCacheURL.path) {
            return .upToDate(version: bundled.version)
        }

        try fm.createDirectory(at: anglesiteSupportURL, withIntermediateDirectories: true)
        if fm.fileExists(atPath: npmCacheURL.path) {
            try fm.removeItem(at: npmCacheURL)
        }
        try fm.createDirectory(at: npmCacheURL, withIntermediateDirectories: true)

        try await extract(bundled.url, npmCacheURL)

        try bundled.version.write(to: versionStampURL, atomically: true, encoding: .utf8)
        return .extracted(version: bundled.version)
    }

    /// `npm` arguments that install against the primed cache, preferring it over the network
    /// (falls back to the registry only for cache misses). Append site-specific flags via `extra`.
    public func npmInstallArguments(extra: [String] = []) -> [String] {
        ["install", "--prefer-offline", "--cache", npmCacheURL.path] + extra
    }

    // MARK: Defaults

    /// Resolves `<bundle>/npm-cache/cache.tar` + `<bundle>/npm-cache/version.txt`, or `nil` if the
    /// archive isn't present.
    public static func resolveBundledArchive(in bundle: Bundle) -> BundledArchive? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let dir = resourceURL.appendingPathComponent("npm-cache", isDirectory: true)
        let archive = dir.appendingPathComponent("cache.tar")
        guard FileManager.default.fileExists(atPath: archive.path) else { return nil }
        let versionFile = dir.appendingPathComponent("version.txt")
        let version = (try? String(contentsOf: versionFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return BundledArchive(url: archive, version: (version?.isEmpty == false ? version! : "unknown"))
    }

    static func defaultApplicationSupportURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// Extractor backed by `/usr/bin/tar -xf <archive> -C <dest>`, spawned through `ProcessSupervisor`
    /// so all subprocess creation stays centralized.
    public static func makeTarExtractor(supervisor: ProcessSupervisor = .shared) -> Extractor {
        { archive, dest in
            let result = try await supervisor.run(
                executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xf", archive.path, "-C", dest.path]
            )
            guard result.exitCode == 0 else {
                throw CacheError.extractionFailed(exitCode: result.exitCode, stderr: result.stderr)
            }
        }
    }
}
