import Foundation

/// Production `ContentOperationsService`: resolves the site's directory, gets an MCP client from a
/// `HeadlessRuntimePool` (spawning one headlessly when no window is open), and calls the plugin's
/// `create_page` / `create_post` tools (A.5/#139, backed by A.4 #138 and the plugin tools #140).
public struct ContentOperations: ContentOperationsService {
    private let pool: HeadlessRuntimePool
    /// Maps a siteID to its on-disk directory (wired to `SiteStore` in bootstrap). `nil` → unknown site.
    private let siteDirectory: @Sendable (_ siteID: String) async -> URL?

    public init(
        pool: HeadlessRuntimePool,
        siteDirectory: @escaping @Sendable (_ siteID: String) async -> URL?
    ) {
        self.pool = pool
        self.siteDirectory = siteDirectory
    }

    public func createPage(siteID: String, name: String, route: String?) async -> ContentCreateResult {
        var args: [String: JSONValue] = ["name": .string(name)]
        if let route, !route.isEmpty { args["route"] = .string(route) }
        return await create(siteID: siteID, tool: "create_page", arguments: args, identifierKey: "route")
    }

    public func createPost(siteID: String, title: String, collection: String?, slug: String?) async -> ContentCreateResult {
        var args: [String: JSONValue] = ["title": .string(title)]
        if let collection, !collection.isEmpty { args["collection"] = .string(collection) }
        if let slug, !slug.isEmpty { args["slug"] = .string(slug) }
        return await create(siteID: siteID, tool: "create_post", arguments: args, identifierKey: "slug")
    }

    private func create(
        siteID: String,
        tool: String,
        arguments: [String: JSONValue],
        identifierKey: String
    ) async -> ContentCreateResult {
        guard let directory = await siteDirectory(siteID) else { return .siteNotFound }
        guard let runtime = await pool.runtime(siteID: siteID, siteDirectory: directory) else {
            return .failed(reason: "Couldn't start the Anglesite plugin for this site.")
        }
        let client = runtime.mcpClient
        do {
            let result = try await client.callTool(name: tool, arguments: .object(arguments))
            let text = result.content.compactMap(\.text).joined(separator: "\n")
            if result.isError {
                return .failed(reason: text.isEmpty ? "The plugin rejected the request." : text)
            }
            guard let parsed = Self.parseCreated(text, identifierKey: identifierKey) else {
                return .failed(reason: "The plugin's reply couldn't be read.")
            }
            return .created(filePath: parsed.filePath, identifier: parsed.identifier)
        } catch {
            return .failed(reason: "\(error)")
        }
    }

    /// Pull `filePath` and the identifier (`route`/`slug`) out of the tool's JSON reply text.
    static func parseCreated(_ text: String, identifierKey: String) -> (filePath: String, identifier: String)? {
        guard !text.isEmpty,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let filePath = json["filePath"] as? String,
              let identifier = json[identifierKey] as? String
        else { return nil }
        return (filePath, identifier)
    }
}
