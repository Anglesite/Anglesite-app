import Foundation

/// Deterministic handling for an optional owner-supplied logo selected in the new-site wizard.
public enum LogoAsset {
    public static let assetDirectoryRelativePath = "public"

    public enum InstallError: Error, Sendable {
        case sourceLogoNotFound(URL)
        case homepageNotFound(URL)
    }

    public static func fileName(for logoURL: URL) -> String {
        let ext = logoURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return ext.isEmpty ? "logo" : "logo.\(ext.lowercased())"
    }

    public static func publicURLPath(for logoURL: URL) -> String {
        "/\(fileName(for: logoURL))"
    }

    public static func insertLogo(into source: String, urlPath: String, alt: String) -> String {
        guard source.contains(HeroImage.heroOpenLine) else { return source }
        guard !source.contains(#"class="site-logo""#) else { return source }
        let img = #"<img src="\#(urlPath)" alt="\#(HeroImage.attr(alt))" class="site-logo" />"#
        return source.replacingOccurrences(of: HeroImage.heroOpenLine, with: HeroImage.heroOpenLine + "\n      " + img)
    }

    public static func install(from logoURL: URL, siteName: String,
                               siteDirectory: URL, fileManager: FileManager = .default) throws -> String {
        guard fileManager.fileExists(atPath: logoURL.path) else {
            throw InstallError.sourceLogoNotFound(logoURL)
        }

        let publicDir = siteDirectory.appendingPathComponent(assetDirectoryRelativePath, isDirectory: true)
        try fileManager.createDirectory(at: publicDir, withIntermediateDirectories: true)
        let dest = publicDir.appendingPathComponent(fileName(for: logoURL))
        if fileManager.fileExists(atPath: dest.path) { try fileManager.removeItem(at: dest) }
        try fileManager.copyItem(at: logoURL, to: dest)

        let publicPath = publicURLPath(for: logoURL)
        let homepage = siteDirectory.appendingPathComponent("src/pages/index.astro")
        guard fileManager.fileExists(atPath: homepage.path) else {
            throw InstallError.homepageNotFound(homepage)
        }
        let src = try String(contentsOf: homepage, encoding: .utf8)
        let patched = insertLogo(into: src, urlPath: publicPath, alt: "\(siteName) logo")
        if patched != src {
            try patched.write(to: homepage, atomically: true, encoding: .utf8)
        }
        return publicPath
    }
}
