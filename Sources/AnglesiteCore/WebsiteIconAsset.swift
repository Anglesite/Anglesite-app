import Foundation

/// Deterministic website icon links and metadata for an Anglesite site's public assets.
public enum WebsiteIconAsset {
    public static let publicDirectoryRelativePath = "public"
    public static let layoutRelativePath = "src/layouts/BaseLayout.astro"
    public static let faviconICOName = "favicon.ico"
    public static let faviconPNGName = "favicon.png"
    public static let appleTouchIconName = "apple-touch-icon.png"
    public static let icon192Name = "icon-192.png"
    public static let icon512Name = "icon-512.png"
    public static let manifestName = "site.webmanifest"

    public enum InstallError: Error, Sendable {
        case layoutNotFound(URL)
    }

    public static let headLinks = """
        <link rel="icon" href="/favicon.ico" sizes="any" />
        <link rel="icon" type="image/png" href="/favicon.png" />
        <link rel="apple-touch-icon" href="/apple-touch-icon.png" />
        <link rel="manifest" href="/site.webmanifest" />
    """

    public static func insertHeadLinks(into source: String) -> String {
        guard !source.contains(#"href="/favicon.ico""#),
              !source.contains(#"href="/site.webmanifest""#) else {
            return source
        }
        guard let headRange = source.range(of: "<head>") else { return source }
        let insertion = "\n" + headLinks
        var patched = source
        patched.insert(contentsOf: insertion, at: headRange.upperBound)
        return patched
    }

    public static func patchLayout(in siteDirectory: URL, fileManager: FileManager = .default) throws {
        let layoutURL = siteDirectory.appendingPathComponent(layoutRelativePath)
        guard fileManager.fileExists(atPath: layoutURL.path) else {
            throw InstallError.layoutNotFound(layoutURL)
        }
        let source = try String(contentsOf: layoutURL, encoding: .utf8)
        let patched = insertHeadLinks(into: source)
        if patched != source {
            try patched.write(to: layoutURL, atomically: true, encoding: .utf8)
        }
    }

    public static func manifestData(siteName: String) throws -> Data {
        let manifest: [String: Any] = [
            "name": siteName,
            "short_name": siteName,
            "icons": [
                [
                    "src": "/icon-192.png",
                    "sizes": "192x192",
                    "type": "image/png"
                ],
                [
                    "src": "/icon-512.png",
                    "sizes": "512x512",
                    "type": "image/png"
                ]
            ],
            "display": "standalone"
        ]
        return try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    }

    public static func installedIconURLs(in siteDirectory: URL) -> [URL] {
        let publicDir = siteDirectory.appendingPathComponent(publicDirectoryRelativePath, isDirectory: true)
        return [
            faviconICOName,
            faviconPNGName,
            appleTouchIconName,
            icon192Name,
            icon512Name,
            manifestName
        ].map { publicDir.appendingPathComponent($0) }
    }

    public static func hasInstalledIcons(in siteDirectory: URL, fileManager: FileManager = .default) -> Bool {
        installedIconURLs(in: siteDirectory).contains { fileManager.fileExists(atPath: $0.path) }
    }
}
