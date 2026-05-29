import Foundation

/// Applies a `Theme` to a site's `src/styles/global.css` by rewriting the values of the
/// `--<key>` custom properties the theme provides. Properties without a matching theme key
/// (spacing, radius, shadows, type scale) are left untouched. Pure + idempotent.
public enum ThemeApplier {
    public enum ApplyError: Error, Sendable { case cssNotFound(URL) }

    public static func apply(_ theme: Theme, toCSS css: String) -> String {
        var result = css
        for (key, value) in theme.cssVars {
            // Match `--key:` then everything up to the line-ending `;`, replace the value.
            // Pattern assumes one declaration per line with a trailing `;` (true of all
            // Astro-generated global.css files); multi-line values are intentionally not matched.
            let pattern = "(--" + NSRegularExpression.escapedPattern(for: key) + ":)[^;\\n]*;"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = result as NSString
            // `$1` keeps `--key:`; template is literal so escape backslashes/$ in the value.
            let safeValue = value.replacingOccurrences(of: "\\", with: "\\\\")
                                 .replacingOccurrences(of: "$", with: "\\$")
            result = re.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: "$1 " + safeValue + ";"
            )
        }
        return result
    }

    public static func apply(_ theme: Theme, siteDirectory: URL, fileManager: FileManager = .default) throws {
        let cssURL = siteDirectory.appendingPathComponent("src/styles/global.css")
        guard fileManager.fileExists(atPath: cssURL.path) else {
            throw ApplyError.cssNotFound(cssURL)
        }
        let css = try String(contentsOf: cssURL, encoding: .utf8)
        let updated = apply(theme, toCSS: css)
        try updated.write(to: cssURL, atomically: true, encoding: .utf8)
    }
}
