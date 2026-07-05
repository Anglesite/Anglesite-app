import Foundation

/// Reduces a raw deploy log to the deploy-relevant portion before it is summarized on-device.
/// Drops `npm run build` / bundler progress noise, then keeps the tail (where failures surface),
/// capped to fit comfortably inside the on-device model's ~4k-token window.
public enum DeployLogDigest {
    /// Character budget for the digest. The on-device window is ~4,096 tokens (≈16k chars);
    /// 6,000 leaves ample room for the prompt and the guided-generation schema.
    public static let maxCharacters = 6_000

    /// Extract the deploy-relevant text from a raw log. Pure and total.
    public static func extract(from logText: String) -> String {
        let lines = logText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let kept = lines.filter { !isBuildNoise($0) }
        var digest = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Single-pass tail trim: index arithmetic avoids the double O(n) walk of `count` + `suffix`.
        if let start = digest.index(digest.endIndex, offsetBy: -maxCharacters, limitedBy: digest.startIndex) {
            digest = String(digest[start...])
        }
        return digest
    }

    /// Conservative: only drops lines that are unambiguously build/bundler progress, so a
    /// wrangler error line (which never matches these) always survives.
    private static func isBuildNoise(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("npm run build") { return true }
        // npm script echo, e.g. "> astro build" — require an identifier after "> " so we don't
        // drop wrangler/JSON lines like "> https://…" or "> {".
        if trimmed.range(of: #"^> \w"#, options: .regularExpression) != nil { return true }
        if trimmed.hasPrefix("✓ ") { return true }                 // Vite "✓ N modules transformed"
        if trimmed.lowercased().hasPrefix("vite v") { return true } // Vite banner
        if trimmed.lowercased().hasPrefix("transforming") { return true }
        return false
    }
}
