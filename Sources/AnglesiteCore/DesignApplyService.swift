// Sources/AnglesiteCore/DesignApplyService.swift
import Foundation

public struct DesignApplyInput: Sendable {
    public let cssVars: [String: String]
    public let rationaleMarkdown: String?
    public let brandSummary: String
    public let sourceLabel: String

    public init(cssVars: [String: String], rationaleMarkdown: String?, brandSummary: String, sourceLabel: String) {
        self.cssVars = cssVars; self.rationaleMarkdown = rationaleMarkdown
        self.brandSummary = brandSummary; self.sourceLabel = sourceLabel
    }
}

public struct AppliedDesign: Sendable, Equatable {
    public let updatedVars: [String: String]
    public let writtenFiles: [String]
}

public enum DesignApplyError: Error, Sendable, Equatable {
    case missingGlobalCSS
    case missingRootBlock
    case writeFailed(String)
}

/// The single writer for applying a design to a site's `Source/` directory — shared by the
/// built-in/freedesignmd theme-apply wizard and (later) the design-interview conversation, so
/// there is exactly one "write design to disk" implementation.
public enum DesignApplyService {
    static let globalCSSRelativePath = "src/styles/global.css"
    static let rationaleRelativePath = "docs/DESIGN.md"
    static let brandRelativePath = "docs/brand.md"

    public static func apply(
        _ input: DesignApplyInput,
        to sourceDirectory: URL,
        fileManager: FileManager = .default
    ) -> Result<AppliedDesign, DesignApplyError> {
        let cssURL = sourceDirectory.appendingPathComponent(globalCSSRelativePath)
        guard let original = try? String(contentsOf: cssURL, encoding: .utf8) else {
            return .failure(.missingGlobalCSS)
        }
        guard let updatedCSS = upsertRootVars(input.cssVars, in: original) else {
            return .failure(.missingRootBlock)
        }

        var written: [String] = []
        do {
            try updatedCSS.write(to: cssURL, atomically: true, encoding: .utf8)
            written.append(globalCSSRelativePath)

            if let rationaleMarkdown = input.rationaleMarkdown {
                let rationaleURL = sourceDirectory.appendingPathComponent(rationaleRelativePath)
                try fileManager.createDirectory(at: rationaleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try rationaleMarkdown.write(to: rationaleURL, atomically: true, encoding: .utf8)
                written.append(rationaleRelativePath)
            }

            let brandURL = sourceDirectory.appendingPathComponent(brandRelativePath)
            try fileManager.createDirectory(at: brandURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existingBrand = (try? String(contentsOf: brandURL, encoding: .utf8)) ?? ""
            let entry = "\n## \(input.sourceLabel)\n\n\(input.brandSummary)\n"
            try (existingBrand + entry).write(to: brandURL, atomically: true, encoding: .utf8)
            written.append(brandRelativePath)
        } catch {
            return .failure(.writeFailed((error as NSError).localizedDescription))
        }

        return .success(AppliedDesign(updatedVars: input.cssVars, writtenFiles: written))
    }

    /// Replaces or appends `--<key>: <value>;` lines inside the first `:root { ... }` block,
    /// leaving everything else in the file untouched. Returns `nil` if no `:root` block is found.
    static func upsertRootVars(_ vars: [String: String], in css: String) -> String? {
        guard let rootRange = css.range(of: ":root"),
              let openBrace = css.range(of: "{", range: rootRange.upperBound..<css.endIndex),
              let closeBrace = css.range(of: "}", range: openBrace.upperBound..<css.endIndex)
        else { return nil }

        var body = String(css[openBrace.upperBound..<closeBrace.lowerBound])
        var remaining = vars

        for key in vars.keys {
            let pattern = #"(--\#(NSRegularExpression.escapedPattern(for: key))\s*:\s*)[^;]*;"#
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(body.startIndex..<body.endIndex, in: body)
            if let match = re.firstMatch(in: body, range: range), let matchRange = Range(match.range, in: body) {
                body.replaceSubrange(matchRange, with: "--\(key): \(vars[key]!);")
                remaining.removeValue(forKey: key)
            }
        }

        if !remaining.isEmpty {
            let additions = remaining.sorted(by: { $0.key < $1.key })
                .map { "  --\($0.key): \($0.value);" }.joined(separator: "\n")
            if !body.hasSuffix("\n") { body += "\n" }
            body += additions + "\n"
        }

        return String(css[css.startIndex..<openBrace.upperBound]) + body + String(css[closeBrace.lowerBound...])
    }
}
