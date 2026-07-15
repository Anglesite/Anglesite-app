import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Discovers a target URL's declared Webmention receiver endpoint per the webmention.org spec:
/// fetch the target once, prefer an HTTP `Link` header with `rel=webmention` (or the legacy
/// `rel="http://webmention.org/"` form), falling back to the first `<link>` or `<a>` element (in
/// document order) with `rel=webmention` in the HTML body. A relative endpoint URL is resolved
/// against the *final* response URL (after redirects), not the originally-requested target —
/// required for pages like webmention.rocks' redirect test.
public enum WebmentionEndpointDiscovery {
    /// Performs one HTTP request and returns its body + response. Throws on connection failure.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// `nil` means the target declares no Webmention endpoint — not an error condition.
    public static func discover(target: URL, transport: Transport) async throws -> URL? {
        var request = URLRequest(url: target)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, http) = try await transport(request)
        let finalURL = http.url ?? target

        if let linkHeader = http.value(forHTTPHeaderField: "Link"),
           let endpoint = endpoint(fromLinkHeader: linkHeader, relativeTo: finalURL) {
            return endpoint
        }
        guard let html = decodeHTML(data) else { return nil }
        return endpoint(fromHTML: html, relativeTo: finalURL)
    }

    /// Decodes the response body as text for markup scanning. Tries UTF-8 first (the HTML5-
    /// mandated default), then falls back to ISO Latin-1 — which never fails, since every byte
    /// maps to a valid Latin-1 codepoint — so a non-UTF-8 page (Latin-1/Windows-1252, no charset
    /// declared) is never silently indistinguishable from "this page declares no endpoint." The
    /// webmention tag/attribute syntax scanned for below is always plain ASCII, which decodes
    /// identically under UTF-8 and Latin-1, so this fallback still finds real endpoints even when
    /// it can't correctly render the surrounding prose.
    private static func decodeHTML(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: Link header

    static func endpoint(fromLinkHeader header: String, relativeTo baseURL: URL) -> URL? {
        for value in splitLinkHeaderValues(header) {
            guard let start = value.firstIndex(of: "<"),
                  let end = value.firstIndex(of: ">"),
                  start < end
            else { continue }
            let urlString = String(value[value.index(after: start)..<end])
            let params = String(value[value.index(after: end)...])
            guard let rel = attributeValue("rel", in: params), isWebmentionRel(rel) else { continue }
            return URL(string: urlString, relativeTo: baseURL)?.absoluteURL
        }
        return nil
    }

    /// Splits a `Link` header on top-level commas — commas inside `<...>` (the URL itself) don't
    /// separate link-values.
    private static func splitLinkHeaderValues(_ header: String) -> [String] {
        var values: [String] = []
        var depth = 0
        var current = ""
        for char in header {
            switch char {
            case "<":
                depth += 1
                current.append(char)
            case ">":
                depth -= 1
                current.append(char)
            case "," where depth == 0:
                values.append(current)
                current = ""
            default:
                current.append(char)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { values.append(current) }
        return values
    }

    // MARK: HTML

    /// Matches `<link ...>` and `<a ...>` tags in document order; the first with a `webmention`
    /// rel wins, per the spec ("the first link or a element ... in document order").
    ///
    /// Known, accepted limitation: `[^>]*` truncates the tag at the first literal `>`, including
    /// one embedded inside a quoted attribute value (e.g. `href="/x?a=1>2"`). A correct HTML
    /// tokenizer would track quote state to know that `>` isn't a tag terminator there. This is a
    /// conscious won't-fix, not an oversight — a literal, unencoded `>` inside an attribute value
    /// is invalid per the URL spec (it must be percent-encoded as `%3E`) and vanishingly rare in
    /// real-world markup; handling it would mean replacing this regex scan with a full tokenizer
    /// for a case that essentially never occurs.
    private static let tagPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"<(?:link|a)\b([^>]*)>"#, options: [.caseInsensitive])
        } catch {
            fatalError("Invalid webmention discovery tag regex: \(error)")
        }
    }()

    static func endpoint(fromHTML html: String, relativeTo baseURL: URL) -> URL? {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in tagPattern.matches(in: html, range: range) {
            guard let attrsRange = Range(match.range(at: 1), in: html) else { continue }
            let attrs = String(html[attrsRange])
            guard let rel = attributeValue("rel", in: attrs), isWebmentionRel(rel) else { continue }
            guard let href = attributeValue("href", in: attrs) else { continue }
            if let url = URL(string: href, relativeTo: baseURL)?.absoluteURL {
                return url
            }
        }
        return nil
    }

    // MARK: Shared attribute/rel helpers

    private static let legacyWebmentionRels: Set<String> = [
        "http://webmention.org/", "https://webmention.org/",
        "http://webmention.org", "https://webmention.org",
    ]

    private static func isWebmentionRel(_ rel: String) -> Bool {
        rel.split(whereSeparator: { $0.isWhitespace }).contains { token in
            token.caseInsensitiveCompare("webmention") == .orderedSame
                || legacyWebmentionRels.contains(String(token).lowercased())
        }
    }

    /// Extracts `name="value"` / `name='value'` / `name=value` from an HTML tag's attribute
    /// string or an HTTP Link-header parameter string. The lookahead-free anchor
    /// `(?:^|[\s;<])` before `name` requires the name to start at the beginning of the source,
    /// or be preceded by whitespace, a `;` (Link-header parameter separator), or `<` — so a
    /// lookup for `rel` does not match inside a longer attribute name like `data-rel=`. (A
    /// plain `\b` word-boundary anchor does *not* achieve this: `-` is a non-word character, so
    /// `\brel\b` still matches the `rel` inside `data-rel=`.)
    private static let relRegex = attributeRegex(for: "rel")
    private static let hrefRegex = attributeRegex(for: "href")

    private static func attributeRegex(for name: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(
                pattern: "(?:^|[\\s;<])\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))",
                options: [.caseInsensitive]
            )
        } catch {
            fatalError("Invalid webmention discovery attribute regex for \(name): \(error)")
        }
    }

    private static func attributeValue(_ name: String, in source: String) -> String? {
        let regex: NSRegularExpression
        switch name {
        case "rel": regex = relRegex
        case "href": regex = hrefRegex
        default: regex = attributeRegex(for: name)
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: range) else { return nil }
        for groupIndex in [2, 3, 4] {
            let group = match.range(at: groupIndex)
            if group.location != NSNotFound, let r = Range(group, in: source) {
                return String(source[r])
            }
        }
        return nil
    }
}
