import Foundation

public struct FreedesignmdSystem: Sendable, Equatable, Identifiable {
    public let slug: String
    public let name: String
    public var id: String { slug }
    public init(slug: String, name: String) { self.slug = slug; self.name = name }
}

public struct FreedesignmdSystemDetail: Sendable, Equatable {
    public let system: FreedesignmdSystem
    public let description: String
    public init(system: FreedesignmdSystem, description: String) { self.system = system; self.description = description }
}

public enum FreedesignmdCatalogError: Error, Sendable, Equatable {
    case fetchFailed(String)
    case parseFailed
}

/// Browses the freedesignmd.com catalog deterministically. The catalog page has no JSON API, but
/// server-renders a JSON-LD `ItemList` with every system's slug/name — this parses that block
/// directly rather than doing LLM-mediated page extraction (unlike the plugin's WebFetch-based
/// `freedesignmd` skill), following `ThemeCatalog.parse(themesTS:)`'s tolerant-regex pattern.
public enum FreedesignmdCatalog {
    static let systemsURL = URL(string: "https://freedesignmd.com/systems")!
    static func systemURL(slug: String) -> URL { URL(string: "https://freedesignmd.com/system/\(slug)")! }

    private static let listItemPattern = #""url":"https://freedesignmd\.com/system/([a-z0-9-]+)","name":"([^"]+)""#
    private static let descriptionPattern = #"name="description" content="([^"]*)""#

    public static func parseSystemList(html: String) -> [FreedesignmdSystem] {
        guard let re = try? NSRegularExpression(pattern: listItemPattern) else { return [] }
        let ns = html as NSString
        return re.matches(in: html, range: NSRange(location: 0, length: ns.length)).map {
            FreedesignmdSystem(slug: ns.substring(with: $0.range(at: 1)), name: ns.substring(with: $0.range(at: 2)))
        }
    }

    public static func parseDescription(html: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: descriptionPattern) else { return nil }
        let ns = html as NSString
        guard let match = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// Fetches and parses the `/systems` catalog page's JSON-LD `ItemList`.
    ///
    /// - Important: As of 2026-07-10, the server-rendered `/systems` page's JSON-LD
    ///   `itemListElement` only includes the first ~50 of the catalog's ~108 entries (per the
    ///   JSON-LD's own `numberOfItems`); the remainder load via client-side pagination not
    ///   present in this parse. This is a known constraint of the deterministic (non-LLM)
    ///   parsing approach — callers should not assume completeness.
    public static func fetchSystemList(session: URLSession = .shared) async throws -> [FreedesignmdSystem] {
        let (data, response) = try await session.data(from: systemsURL)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let html = String(data: data, encoding: .utf8)
        else { throw FreedesignmdCatalogError.fetchFailed("bad response from \(systemsURL)") }
        let systems = parseSystemList(html: html)
        guard !systems.isEmpty else { throw FreedesignmdCatalogError.parseFailed }
        return systems
    }

    public static func fetchDescription(slug: String, session: URLSession = .shared) async throws -> String? {
        let (data, response) = try await session.data(from: systemURL(slug: slug))
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let html = String(data: data, encoding: .utf8)
        else { throw FreedesignmdCatalogError.fetchFailed("bad response for \(slug)") }
        return parseDescription(html: html)
    }

    /// Deterministic pre-filter: scores each system by how many whitespace-separated keywords from
    /// `businessType` appear as a substring of its name (case-insensitive), descending. Ties keep
    /// original catalog order (Swift's `sorted` is stable). Falls back to the original order when
    /// `businessType` is empty or nothing matches.
    public static func rank(_ systems: [FreedesignmdSystem], byKeywordsIn businessType: String) -> [FreedesignmdSystem] {
        let keywords = businessType.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !keywords.isEmpty else { return systems }
        func score(_ system: FreedesignmdSystem) -> Int {
            let name = system.name.lowercased()
            return keywords.reduce(0) { $0 + (name.contains($1) ? 1 : 0) }
        }
        return systems.enumerated()
            .sorted { a, b in
                let (sa, sb) = (score(a.element), score(b.element))
                return sa == sb ? a.offset < b.offset : sa > sb
            }
            .map(\.element)
    }
}
