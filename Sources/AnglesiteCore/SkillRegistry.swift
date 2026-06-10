import Foundation

/// Reads the bundled Anglesite plugin's skills directory and surfaces a small data shape
/// the chat panel can use to render quick-action buttons.
///
/// Each skill lives at `<plugin>/skills/<name>/SKILL.md` with a YAML frontmatter block at
/// the top. We only parse two keys today (`name`, `description`) — enough to label a
/// button and tooltip it. The parser is intentionally tiny rather than pulling in a YAML
/// library: SKILL.md frontmatter follows a stable, narrow shape and adding a dep just for
/// two string fields would be overkill.
///
/// The "which skills become buttons" decision is bounded by `quickActionNames` so the chat
/// toolbar stays a handful of buttons rather than 28. Names are the canonical owner-triggered
/// v0.5 core set; labels and tooltips come from the plugin so they stay in sync as the
/// SKILL.md descriptions evolve. A future plugin-side change (e.g. a `featured.json`
/// manifest) can replace the hard-coded list without changing this file's API.
public enum SkillRegistry {
    public struct Skill: Sendable, Equatable, Identifiable {
        public let name: String
        public let description: String?
        public var id: String { name }

        public init(name: String, description: String?) {
            self.name = name
            self.description = description
        }
    }

    /// Curated v0.5 quick-action set, in display order. Hard-coded here because exposing all
    /// owner-triggered skills (28 today, more coming) would overwhelm the chat toolbar.
    ///
    /// Phase A dissolved this list as deterministic structured buttons replaced each pill:
    /// `deploy` left for the toolbar Deploy button (#84); `backup` for the toolbar Backup
    /// button (#85); `check` for the toolbar Audit button + `AuditSheetView` (#86). All
    /// three call their respective `*Command` actors directly, skipping the LLM for
    /// actions Claude was just invoking the same way every time. The chat path still
    /// works for natural-language phrasings ("audit my site"); only the dedicated pills
    /// are gone. `import` remains because it's an interactive flow that benefits from
    /// LLM-assisted disambiguation of source URLs / formats.
    public static let quickActionNames: [String] = ["import"]

    /// Discover skills under `<pluginDirectory>/skills/`. Returns all readable skills in
    /// directory order; the caller filters down (e.g. by `quickActionNames`) for display.
    /// Skills with unreadable or malformed SKILL.md files are silently skipped — better to
    /// surface a subset than to fail loudly when one upstream skill has a syntax glitch.
    public static func discover(pluginDirectory: URL, fileManager: FileManager = .default) -> [Skill] {
        let skillsDir = pluginDirectory.appendingPathComponent("skills", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var skills: [Skill] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let skillFile = entry.appendingPathComponent("SKILL.md")
            guard let raw = try? String(contentsOf: skillFile, encoding: .utf8) else { continue }
            guard let skill = parseSkillFrontmatter(raw) else { continue }
            skills.append(skill)
        }
        return skills
    }

    /// Convenience: discover + filter + reorder to match `quickActionNames`. Returns only
    /// the skills that were both in the curated list and present on disk, in curated order.
    public static func quickActions(in pluginDirectory: URL, fileManager: FileManager = .default) -> [Skill] {
        let all = discover(pluginDirectory: pluginDirectory, fileManager: fileManager)
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        return quickActionNames.compactMap { byName[$0] }
    }

    /// Parse the YAML frontmatter block at the top of `SKILL.md`. The shape is:
    ///
    ///     ---
    ///     name: deploy
    ///     description: "Build, scan, and deploy"
    ///     allowed-tools: …
    ///     ---
    ///     <body markdown>
    ///
    /// We only consume `name` and `description`. Values may be quoted (single or double)
    /// or bare; quotes are stripped if present on both ends. Multi-line values aren't
    /// supported (the SKILL.md format keeps descriptions to a single line in practice).
    public static func parseSkillFrontmatter(_ source: String) -> Skill? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        // Frontmatter must open with `---` on the very first line.
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var name: String?
        var description: String?
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }  // end of frontmatter
            // Split on the *first* colon to allow colons inside quoted values.
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            let rawValue = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let value = stripQuotes(String(rawValue))
            switch key {
            case "name":        name = value
            case "description": description = value
            default: continue
            }
        }
        guard let name, !name.isEmpty else { return nil }
        return Skill(name: name, description: description?.isEmpty == false ? description : nil)
    }

    private static func stripQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first!
        let last = s.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
