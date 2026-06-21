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
        if let r = content.range(of: start), let e = content.range(of: end), r.lowerBound < e.lowerBound {
            let replaced = content.replacingCharacters(in: r.lowerBound..<e.upperBound, with: block)
            return .success(replaced)
        }
        // Otherwise strip any orphaned lone marker lines (self-healing), then insert before anchor.
        guard let a = content.range(of: anchor) else { return .failure(.anchorNotFound(anchor)) }
        let stripped = content
            .components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) != start && $0.trimmingCharacters(in: .whitespaces) != end }
            .joined(separator: "\n")
        let a2 = stripped.range(of: anchor)!
        let inserted = stripped.replacingCharacters(in: a2.lowerBound..<a2.lowerBound, with: "\(block)\n")
        return .success(inserted)
    }
}
