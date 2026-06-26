import Foundation

/// Pre-fills the scaffolded homepage (`src/pages/index.astro`) with the owner's headline and
/// blurb by replacing the known template strings. Operates on known content (safe targeted
/// replace, not a fuzzy patch).
public enum HomepageWriter {
    public enum WriteError: Error, Sendable { case homepageNotFound(URL) }

    // The exact strings the template ships.
    static let titleLine =
        #"title="Welcome — Your New Anglesite Business Website""#
    static let descLine =
        #"description="Your business website is ready to set up in Anglesite.""#
    static let h1Line = "<h1>Welcome</h1>"
    static let introLine =
        "<p>This site is ready to customize in Anglesite. Open the app to edit your pages, add content, and publish when you're ready.</p>"

    public static func fill(_ source: String, headline: String, blurb: String, tagline: String) -> String {
        var out = source
        let h = headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = blurb.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = tagline.trimmingCharacters(in: .whitespacesAndNewlines)

        if !h.isEmpty {
            out = out.replacingOccurrences(of: titleLine, with: #"title=""# + attr(h) + #"""#)
            out = out.replacingOccurrences(of: h1Line, with: "<h1>" + markup(h) + "</h1>")
        }
        let description = !b.isEmpty ? b : t
        if !description.isEmpty {
            out = out.replacingOccurrences(of: descLine, with: #"description=""# + attr(description) + #"""#)
        }
        if !b.isEmpty {
            out = out.replacingOccurrences(of: introLine, with: "<p>" + markup(b) + "</p>")
        }
        return out
    }

    public static func write(headline: String, blurb: String, tagline: String,
                             siteDirectory: URL, fileManager: FileManager = .default) throws {
        let url = siteDirectory.appendingPathComponent("src/pages/index.astro")
        guard fileManager.fileExists(atPath: url.path) else {
            throw WriteError.homepageNotFound(url)
        }
        let src = try String(contentsOf: url, encoding: .utf8)
        try fill(src, headline: headline, blurb: blurb, tagline: tagline)
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// Escape for a double-quoted HTML attribute.
    private static func attr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Escape for HTML text content.
    private static func markup(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
