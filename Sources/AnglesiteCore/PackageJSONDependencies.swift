import Foundation

/// Reads and surgically rewrites the `dependencies`/`devDependencies` version
/// ranges in a package.json's raw text. `apply` never re-serializes the whole
/// file — it only replaces the specific `"name": "range"` substrings for accepted
/// offers, leaving formatting, key order, comments-adjacent content, and any
/// dependency the site added on its own completely untouched.
public enum PackageJSONDependencies {
    public enum ExtractionError: Error, Equatable {
        case invalidJSON
    }

    /// The union of `dependencies` and `devDependencies` (name -> version range).
    /// If a name appears in both sections, `devDependencies` wins (checked second).
    public static func extract(from text: String) throws -> [String: String] {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any]
        else { throw ExtractionError.invalidJSON }
        var result: [String: String] = [:]
        if let deps = object["dependencies"] as? [String: String] {
            result.merge(deps) { _, new in new }
        }
        if let devDeps = object["devDependencies"] as? [String: String] {
            result.merge(devDeps) { _, new in new }
        }
        return result
    }

    /// Rewrites `text`, replacing the version-range string for each offer's
    /// package name wherever it appears as a `"name": "range"` pair. A name
    /// present in both `dependencies` and `devDependencies` gets the same new
    /// range in both places (matches `extract`'s dedup rule). A name not found
    /// in the text is silently ignored — `apply` never adds anything.
    public static func apply(_ offers: [DependencyUpdateOffer], to text: String) -> String {
        var result = text
        for offer in offers {
            let escapedName = NSRegularExpression.escapedPattern(for: offer.name)
            guard let regex = try? NSRegularExpression(pattern: "\"\(escapedName)\"\\s*:\\s*\"[^\"]*\"") else { continue }
            let replacement = "\"\(offer.name)\": \"\(offer.offeredRange)\""
            let template = NSRegularExpression.escapedTemplate(for: replacement)
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }
}
