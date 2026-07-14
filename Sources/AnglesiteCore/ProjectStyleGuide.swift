import Foundation

/// Deterministic conventions inferred from the indexed project content.
///
/// This is intentionally local and explainable: no model call is needed to learn the guide, and the
/// assistant receives a compact instruction block before each turn so generated content matches the
/// site's existing shape.
public struct ProjectStyleGuide: Sendable, Equatable {
    public struct Rule: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let detail: String
        public let evidence: [String]

        public init(id: String, title: String, detail: String, evidence: [String] = []) {
            self.id = id
            self.title = title
            self.detail = detail
            self.evidence = evidence
        }
    }

    public let siteID: String
    public let sourceCount: Int
    public let rules: [Rule]

    public init(siteID: String, sourceCount: Int, rules: [Rule]) {
        self.siteID = siteID
        self.sourceCount = sourceCount
        self.rules = rules
    }

    public var isEmpty: Bool { rules.isEmpty }

    public var assistantInstructions: String? {
        guard !rules.isEmpty else { return nil }
        var lines = [
            "Project style guide inferred from existing site content:",
            "When generating or editing content, follow these conventions unless the user asks otherwise.",
        ]
        for rule in rules.prefix(10) {
            lines.append("- \(rule.title): \(rule.detail)")
        }
        return lines.joined(separator: "\n")
    }

    public static func infer(
        siteID: String,
        documents: [SiteKnowledgeIndex.Document]
    ) -> ProjectStyleGuide {
        let contentDocs = documents
            .filter { [.page, .post, .content].contains($0.kind) }
            .sorted { $0.path < $1.path }
        let builder = Builder(siteID: siteID, documents: contentDocs)
        return builder.build()
    }
}

private struct Builder {
    let siteID: String
    let documents: [SiteKnowledgeIndex.Document]

    func build() -> ProjectStyleGuide {
        var rules: [ProjectStyleGuide.Rule] = []
        rules.append(contentsOf: frontmatterRules())
        rules.append(contentsOf: headingRules())
        rules.append(contentsOf: writingRules())
        rules.append(contentsOf: markdownRules())
        rules.append(contentsOf: linkRules())
        rules.append(contentsOf: componentRules())
        return ProjectStyleGuide(siteID: siteID, sourceCount: documents.count, rules: rules)
    }

    private func frontmatterRules() -> [ProjectStyleGuide.Rule] {
        let docsWithFrontmatter = documents.filter { !$0.frontmatter.isEmpty }
        guard !docsWithFrontmatter.isEmpty else { return [] }

        var groups: [String: [[String: FrontmatterValue]]] = [:]
        for doc in docsWithFrontmatter {
            groups[groupName(for: doc.path), default: []].append(doc.frontmatter)
        }

        return groups.sorted { $0.key < $1.key }.compactMap { group, frontmatters in
            let keyCounts = frequency(frontmatters.flatMap { Array($0.keys) })
            let common = keyCounts
                .filter { $0.value >= max(1, Int(Double(frontmatters.count) * 0.6)) }
                .map(\.key)
                .sorted()
            guard !common.isEmpty else { return nil }
            let details = common.map { key in
                "\(key): \(dominantFrontmatterType(for: key, in: frontmatters))"
            }
            return ProjectStyleGuide.Rule(
                id: "frontmatter-\(group)",
                title: "\(group) frontmatter",
                detail: "Common fields are \(details.joined(separator: ", ")).",
                evidence: samplePaths(frontmatters: frontmatters, group: group)
            )
        }
    }

    private func headingRules() -> [ProjectStyleGuide.Rule] {
        let levels = documents.flatMap { headingLevels(in: $0.excerptText) }
        var rules: [ProjectStyleGuide.Rule] = []
        if !levels.isEmpty {
            let mostCommon = frequency(levels).sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }.prefix(3).map { "h\($0.key)" }
            rules.append(ProjectStyleGuide.Rule(
                id: "heading-hierarchy",
                title: "Heading hierarchy",
                detail: "Most content headings use \(mostCommon.joined(separator: ", ")); preserve that level pattern.",
                evidence: documents.filter { !headingLevels(in: $0.excerptText).isEmpty }.prefix(3).map(\.path)
            ))
        }

        let headings = documents.flatMap(\.headings)
        guard headings.count >= 2 else { return rules }
        let titleCaseCount = headings.filter(isLikelyTitleCase).count
        let sentenceCaseCount = headings.count - titleCaseCount
        if titleCaseCount != sentenceCaseCount {
            let style = titleCaseCount > sentenceCaseCount ? "title case" : "sentence case"
            rules.append(ProjectStyleGuide.Rule(
                id: "heading-capitalization",
                title: "Heading capitalization",
                detail: "Headings lean \(style); match that capitalization in new headings.",
                evidence: Array(headings.prefix(3))
            ))
        }
        return rules
    }

    private func writingRules() -> [ProjectStyleGuide.Rule] {
        let text = documents.map(\.excerptText).joined(separator: "\n")
        let sentences = sentenceLengths(in: text)
        var rules: [ProjectStyleGuide.Rule] = []
        if !sentences.isEmpty {
            let average = Int(round(Double(sentences.reduce(0, +)) / Double(sentences.count)))
            let pace = average <= 14 ? "short, direct sentences" : average >= 25 ? "longer, more explanatory sentences" : "medium-length sentences"
            rules.append(ProjectStyleGuide.Rule(
                id: "sentence-pace",
                title: "Sentence pace",
                detail: "Existing copy averages about \(average) words per sentence, so prefer \(pace)."
            ))
        }

        let lower = text.lowercased()
        let firstPerson = countWords(["we", "our", "us", "i", "my"], in: lower)
        let secondPerson = countWords(["you", "your"], in: lower)
        if firstPerson > 2 || secondPerson > 2 {
            let voice = firstPerson >= secondPerson ? "first-person/site-owner language" : "direct reader-facing language"
            rules.append(ProjectStyleGuide.Rule(
                id: "voice",
                title: "Voice",
                detail: "Copy often uses \(voice); keep that point of view consistent."
            ))
        }

        let contractions = matches(#"\b\w+(?:'re|'ve|'ll|'d|'m|n't)\b"#, in: text).count
        if contractions >= 2 {
            rules.append(ProjectStyleGuide.Rule(
                id: "contractions",
                title: "Tone",
                detail: "Contractions appear in existing copy; a conversational tone is acceptable."
            ))
        }
        return rules
    }

    private func markdownRules() -> [ProjectStyleGuide.Rule] {
        let text = documents.map(\.excerptText).joined(separator: "\n")
        var rules: [ProjectStyleGuide.Rule] = []
        let dashBullets = matches(#"(?m)^\s*-\s+"#, in: text).count
        let starBullets = matches(#"(?m)^\s*\*\s+"#, in: text).count
        if dashBullets + starBullets >= 2 {
            let marker = dashBullets >= starBullets ? "`-`" : "`*`"
            rules.append(ProjectStyleGuide.Rule(
                id: "bullet-marker",
                title: "Bullet lists",
                detail: "Use \(marker) as the preferred unordered-list marker."
            ))
        }

        let callouts = matches(#"(?m)^>\s*\[![A-Z]+\]"#, in: text).count
        if callouts > 0 {
            rules.append(ProjectStyleGuide.Rule(
                id: "callouts",
                title: "Callouts",
                detail: "Markdown callouts use the `> [!TYPE]` convention."
            ))
        }

        let fenced = matches(#"(?m)^```[A-Za-z0-9_-]+"#, in: text).count
        let unfenced = matches(#"(?m)^```\s*$"#, in: text).count
        if fenced > 0, fenced >= unfenced {
            rules.append(ProjectStyleGuide.Rule(
                id: "code-fences",
                title: "Code fences",
                detail: "Code blocks usually include a language tag."
            ))
        }
        return rules
    }

    private func linkRules() -> [ProjectStyleGuide.Rule] {
        let links = documents.flatMap(\.internalLinks)
        guard !links.isEmpty else { return [] }
        let absolute = links.filter { $0.hasPrefix("/") }.count
        let relative = links.count - absolute
        let style = absolute >= relative ? "root-relative internal links such as `/about`" : "relative internal links such as `../about`"
        return [
            ProjectStyleGuide.Rule(
                id: "internal-links",
                title: "Internal links",
                detail: "Prefer \(style).",
                evidence: Array(links.prefix(3))
            )
        ]
    }

    private func componentRules() -> [ProjectStyleGuide.Rule] {
        let allComponents = documents.flatMap { componentTags(in: $0.excerptText) }
        guard !allComponents.isEmpty else { return [] }
        let top = frequency(allComponents)
            .sorted { lhs, rhs in lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value }
            .prefix(5)
            .map(\.key)
        return [
            ProjectStyleGuide.Rule(
                id: "components",
                title: "Component usage",
                detail: "Reuse existing components when relevant: \(top.joined(separator: ", "))."
            )
        ]
    }

    private func groupName(for path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 3, parts[0] == "src", parts[1] == "content" {
            return parts[2]
        }
        if path.hasPrefix("src/pages/") { return "pages" }
        return "content"
    }

    private func samplePaths(frontmatters: [[String: FrontmatterValue]], group: String) -> [String] {
        documents.filter { doc in
            groupName(for: doc.path) == group && !doc.frontmatter.isEmpty
        }.prefix(3).map(\.path)
    }
}

private func dominantFrontmatterType(
    for key: String,
    in frontmatters: [[String: FrontmatterValue]]
) -> String {
    let types = frontmatters.compactMap { values -> String? in
        guard let value = values[key] else { return nil }
        switch value {
        case .string: return "text"
        case .bool: return "boolean"
        case .array: return "list"
        case .number: return "number"
        case .date: return "date"
        }
    }
    return frequency(types).max { $0.value < $1.value }?.key ?? "value"
}

private func headingLevels(in source: String) -> [Int] {
    var out = matches(#"(?m)^\s{0,3}(#{1,6})\s+"#, in: source, group: 1).map(\.count)
    out.append(contentsOf: matches(#"<h([1-6])\b"#, in: source, group: 1, options: [.caseInsensitive]).compactMap(Int.init))
    return out
}

private func componentTags(in source: String) -> [String] {
    matches(#"<([A-Z][A-Za-z0-9_.:]*)\b"#, in: source, group: 1)
}

private func sentenceLengths(in source: String) -> [Int] {
    source
        .components(separatedBy: CharacterSet(charactersIn: ".!?"))
        .map { sentence in
            sentence.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.count
        }
        .filter { $0 >= 3 }
}

private func countWords(_ words: [String], in source: String) -> Int {
    words.reduce(0) { total, word in
        total + matches(#"\b\#(NSRegularExpression.escapedPattern(for: word))\b"#, in: source).count
    }
}

private func isLikelyTitleCase(_ value: String) -> Bool {
    let words = value.split { !$0.isLetter }
    guard words.count >= 2 else { return false }
    let meaningful = words.filter { $0.count > 2 }
    guard !meaningful.isEmpty else { return false }
    let capped = meaningful.filter { word in
        guard let first = word.first else { return false }
        return first.isUppercase
    }
    return capped.count >= max(1, meaningful.count - 1)
}

private func frequency<T: Hashable>(_ values: [T]) -> [T: Int] {
    values.reduce(into: [:]) { counts, value in counts[value, default: 0] += 1 }
}

private func matches(
    _ pattern: String,
    in source: String,
    group: Int = 0,
    options: NSRegularExpression.Options = []
) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
        return []
    }
    let range = NSRange(source.startIndex..<source.endIndex, in: source)
    return regex.matches(in: source, range: range).compactMap { match in
        guard let r = Range(match.range(at: group), in: source) else { return nil }
        return String(source[r])
    }
}
