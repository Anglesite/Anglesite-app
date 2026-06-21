// Sources/AnglesiteCore/SiteConfigFile.swift
import Foundation

public enum SiteConfigFile {
    public static let cspKey = "SCRIPT_ALLOW"

    public static func upsert(_ entries: [(key: String, value: String)], into contents: String) -> String {
        var lines = contents.isEmpty ? [] : contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }  // normalize trailing newline
        for (key, value) in entries {
            let line = "\(key)=\(value)"
            if let i = lines.firstIndex(where: { $0.hasPrefix("\(key)=") }) {
                lines[i] = line
            } else {
                lines.append(line)
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    public static func addCSPDomains(_ domains: [String], into contents: String) -> String {
        let existingLine = contents.split(separator: "\n").first { $0.hasPrefix("\(cspKey)=") }
        let existing = existingLine.map { String($0.dropFirst(cspKey.count + 1)) }
            .map { $0.split(separator: ",").map(String.init) } ?? []
        var merged = existing
        for d in domains where !merged.contains(d) { merged.append(d) }
        return upsert([(cspKey, merged.joined(separator: ","))], into: contents)
    }
}
