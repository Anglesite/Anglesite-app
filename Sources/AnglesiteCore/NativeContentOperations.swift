// Sources/AnglesiteCore/NativeContentOperations.swift
import Foundation

/// Native, in-process `create_page` / `create_post`. Byte-faithful to the Node sidecar's
/// `create-content.mjs` (see `ContentScaffold`), but writes the file with `FileManager` and
/// commits best-effort via an injected git closure — no MCP round-trip. Replaces the
/// MCP-routed `ContentOperations` at the App Intents dependency registration.
public struct NativeContentOperations: ContentOperationsService {

    public typealias GitCommit = @Sendable (_ projectRoot: URL, _ relPath: String, _ message: String) async -> String?

    private let siteDirectory: @Sendable (_ siteID: String) async -> URL?
    private let gitCommit: GitCommit
    private let now: @Sendable () -> Date
    // FileManager is a thread-safe singleton but not Sendable; nonisolated(unsafe) preserves the
    // test-injection seam (the plan's intended seam for write-failure paths) without breaking the
    // struct's Sendable conformance.
    private nonisolated(unsafe) let fileManager: FileManager

    public init(
        siteDirectory: @escaping @Sendable (_ siteID: String) async -> URL?,
        gitCommit: @escaping GitCommit = NativeContentOperations.processGitCommit,
        now: @escaping @Sendable () -> Date = { Date() },
        fileManager: FileManager = .default
    ) {
        self.siteDirectory = siteDirectory
        self.gitCommit = gitCommit
        self.now = now
        self.fileManager = fileManager
    }

    public func createPage(siteID: String, name: String, route: String?, onProgress: ProgressHandler? = nil) async -> ContentCreateResult {
        await createPage(siteID: siteID, name: name, route: route, template: .standard, onProgress: onProgress)
    }

    public func createPage(
        siteID: String,
        name: String,
        route: String?,
        template: ContentScaffold.PageTemplate,
        onProgress: ProgressHandler? = nil
    ) async -> ContentCreateResult {
        onProgress?(.createResolvingRuntime)
        guard let root = await siteDirectory(siteID) else { return .siteNotFound }

        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .failed(reason: "create_page requires a non-empty name") }

        let base = route.flatMap { $0.isEmpty ? nil : $0 } ?? ContentScaffold.slugify(title)
        let normalized = ContentScaffold.normalizeRoute(base)
        guard normalized != "/" else {
            return .failed(reason: "create_page can't scaffold the site root; give the page a name or route")
        }

        let relPath = ContentScaffold.pageRelativePath(normalizedRoute: normalized)
        let abs = root.appendingPathComponent(relPath)
        if fileManager.fileExists(atPath: abs.path) {
            return .failed(reason: "A page already exists at \(relPath)")
        }

        onProgress?(.createCallingPlugin)
        let contents = ContentScaffold.renderPage(
            title: title,
            layoutImport: ContentScaffold.layoutImport(normalizedRoute: normalized),
            template: template)
        do { try write(contents, to: abs) }
        catch { return .failed(reason: "\(error)") }

        onProgress?(.createFinalizing)
        _ = await gitCommit(root, relPath, "anglesite: add page \(normalized)")
        return .created(filePath: relPath, identifier: normalized)
    }

    public func createPost(siteID: String, title: String, collection: String?, slug: String?, onProgress: ProgressHandler? = nil) async -> ContentCreateResult {
        onProgress?(.createResolvingRuntime)
        guard let root = await siteDirectory(siteID) else { return .siteNotFound }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return .failed(reason: "create_post requires a non-empty title") }

        let trimmedColl = (collection ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let coll = trimmedColl.isEmpty ? "posts" : trimmedColl
        guard coll.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            return .failed(reason: "Invalid collection name: \(coll)")
        }

        let slugSource = slug.flatMap { $0.isEmpty ? nil : $0 } ?? cleanTitle
        let finalSlug = ContentScaffold.slugify(slugSource)
        guard !finalSlug.isEmpty else { return .failed(reason: "create_post could not derive a slug from the title") }

        let relPath = ContentScaffold.postRelativePath(collection: coll, slug: finalSlug)
        let abs = root.appendingPathComponent(relPath)
        if fileManager.fileExists(atPath: abs.path) {
            return .failed(reason: "A \(coll) entry already exists at \(relPath)")
        }

        onProgress?(.createCallingPlugin)
        let contents = ContentScaffold.renderPost(title: cleanTitle, now: now())
        do { try write(contents, to: abs) }
        catch { return .failed(reason: "\(error)") }

        onProgress?(.createFinalizing)
        _ = await gitCommit(root, relPath, "anglesite: add \(coll) \(finalSlug)")
        return .created(filePath: relPath, identifier: finalSlug)
    }

    public func createCollectionEntry(
        siteID: String,
        title: String,
        descriptor: ContentTypeDescriptor,
        slug: String?,
        onProgress: ProgressHandler? = nil
    ) async -> ContentCreateResult {
        guard let collection = descriptor.collection else {
            return .failed(reason: "\(descriptor.displayName) is not a collection-backed content type")
        }

        onProgress?(.createResolvingRuntime)
        guard let root = await siteDirectory(siteID) else { return .siteNotFound }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return .failed(reason: "New collection entries need a non-empty title") }
        guard collection.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            return .failed(reason: "Invalid collection name: \(collection)")
        }

        let slugSource = slug.flatMap { $0.isEmpty ? nil : $0 } ?? cleanTitle
        let finalSlug = ContentScaffold.slugify(slugSource)
        guard !finalSlug.isEmpty else { return .failed(reason: "Could not derive a slug from the title") }

        let relPath = ContentScaffold.postRelativePath(collection: collection, slug: finalSlug)
        let abs = root.appendingPathComponent(relPath)
        if fileManager.fileExists(atPath: abs.path) {
            return .failed(reason: "A \(collection) entry already exists at \(relPath)")
        }

        onProgress?(.createCallingPlugin)
        let contents = ContentScaffold.renderCollectionEntry(title: cleanTitle, descriptor: descriptor, now: now())
        do { try write(contents, to: abs) }
        catch { return .failed(reason: "\(error)") }

        onProgress?(.createFinalizing)
        _ = await gitCommit(root, relPath, "anglesite: add \(collection) \(finalSlug)")
        return .created(filePath: relPath, identifier: finalSlug)
    }

    private func write(_ contents: String, to abs: URL) throws {
        try fileManager.createDirectory(at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: abs, atomically: true, encoding: .utf8)
    }

    /// Stage and commit exactly `relPath` on the current branch. Returns the new HEAD SHA,
    /// or nil on any failure (not a repo, rejecting hook, git missing) — best-effort, mirroring
    /// the Node sidecar's `commitFile`.
    @Sendable public static func processGitCommit(_ projectRoot: URL, _ relPath: String, _ message: String) async -> String? {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        func run(_ args: [String]) async -> ProcessSupervisor.RunResult? {
            let result = try? await ProcessSupervisor.shared.run(executable: git, arguments: args, currentDirectoryURL: projectRoot)
            guard let result, result.exitCode == 0 else { return nil }
            return result
        }
        guard await run(["rev-parse", "--git-dir"]) != nil,
              await run(["add", "--", relPath]) != nil,
              await run(["commit", "-m", message, "--", relPath]) != nil,
              let head = await run(["rev-parse", "HEAD"]) else { return nil }
        return head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
