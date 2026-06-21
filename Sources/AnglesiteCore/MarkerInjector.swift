// Sources/AnglesiteCore/MarkerInjector.swift
import Foundation

public enum MarkerInjector {
    public enum Failure: Error, Equatable { case anchorNotFound(String) }

    public static func inject(snippet: String, withID id: String, atAnchor anchor: String,
                              into content: String) -> Result<String, Failure> {
        let start = "<!-- anglesite:\(id):start -->"
        let end = "<!-- anglesite:\(id):end -->"
        let block = "\(start)\n\(snippet)\n\(end)"

        // Replace an existing delimited block if present (idempotent re-run).
        if let r = content.range(of: start), let e = content.range(of: end) {
            let replaced = content.replacingCharacters(in: r.lowerBound..<e.upperBound, with: block)
            return .success(replaced)
        }
        // Otherwise insert immediately before the anchor comment.
        guard let a = content.range(of: anchor) else { return .failure(.anchorNotFound(anchor)) }
        let inserted = content.replacingCharacters(in: a.lowerBound..<a.lowerBound, with: "\(block)\n")
        return .success(inserted)
    }
}
