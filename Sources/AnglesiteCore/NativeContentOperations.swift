// Sources/AnglesiteCore/NativeContentOperations.swift
import Foundation

/// Native, in-process `create_page` / `create_post`. Byte-faithful to the Node sidecar's
/// `create-content.mjs` (see `ContentScaffold`), but writes the file with `FileManager` and
/// commits best-effort via an injected git closure — no MCP round-trip. Replaces the
/// MCP-routed `ContentOperations` at the App Intents dependency registration.
public struct NativeContentOperations: ContentOperationsService {

    public typealias GitCommit = @Sendable (_ projectRoot: URL, _ relPath: String, _ message: String) async -> String?
    public typealias GitDelete = @Sendable (_ projectRoot: URL, _ relPath: String, _ message: String) async -> String?

    private let siteDirectory: @Sendable (_ siteID: String) async -> URL?
    private let gitCommit: GitCommit
    private let gitDelete: GitDelete
    private let now: @Sendable () -> Date
    private let copyGenerator: any PageCopyGenerating
    // FileManager is a thread-safe singleton but not Sendable; nonisolated(unsafe) preserves the
    // test-injection seam (the plan's intended seam for write-failure paths) without breaking the
    // struct's Sendable conformance.
    private nonisolated(unsafe) let fileManager: FileManager

    public init(
        siteDirectory: @escaping @Sendable (_ siteID: String) async -> URL?,
        gitCommit: @escaping GitCommit = NativeContentOperations.processGitCommit,
        gitDelete: @escaping GitDelete = NativeContentOperations.processGitDelete,
        now: @escaping @Sendable () -> Date = { Date() },
        copyGenerator: any PageCopyGenerating = NoopPageCopyGenerator(),
        fileManager: FileManager = .default
    ) {
        self.siteDirectory = siteDirectory
        self.gitCommit = gitCommit
        self.gitDelete = gitDelete
        self.now = now
        self.copyGenerator = copyGenerator
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
        let suggestion = await copyGenerator.suggestDescription(title: title, siteID: siteID, siteDirectory: root)
        let contents = ContentScaffold.renderPage(
            title: title,
            layoutImport: ContentScaffold.layoutImport(normalizedRoute: normalized),
            template: template,
            description: suggestion?.description)
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
        let suggestion = await copyGenerator.suggestDescription(title: cleanTitle, siteID: siteID, siteDirectory: root)
        let contents = ContentScaffold.renderPost(title: cleanTitle, now: now(), description: suggestion?.description ?? "")
        do { try write(contents, to: abs) }
        catch { return .failed(reason: "\(error)") }

        onProgress?(.createFinalizing)
        _ = await gitCommit(root, relPath, "anglesite: add \(coll) \(finalSlug)")
        return .created(filePath: relPath, identifier: finalSlug)
    }

    /// `ContentOperationsService` witness: derive the slug from `title` alone. Mirrors the plugin's
    /// `create_content` MCP tool, which takes only `{ type, title }`.
    public func createTyped(siteID: String, typeID: String, title: String, onProgress: ProgressHandler? = nil) async -> ContentCreateResult {
        await createTyped(siteID: siteID, typeID: typeID, title: title, slug: nil, onProgress: onProgress)
    }

    /// Create a typed content entry (V-1.2). Looks the type up in `registry`, derives a slug from
    /// `slug ?? title`, renders frontmatter via `ContentScaffold.renderEntry`, writes it, and commits —
    /// the same write/commit path as `createPost`. Collection-stored types only; singleton-stored types
    /// (e.g. the `profile` identity) go through `createTypedSingleton`. The explicit-`slug` overload
    /// is the native path's superset over the MCP witness (SiteWindow's per-type editor passes a
    /// caller-chosen slug).
    public func createTyped(
        siteID: String,
        typeID: String,
        title: String,
        slug: String?,
        registry: ContentTypeRegistry = ContentTypeRegistry(),
        onProgress: ProgressHandler? = nil
    ) async -> ContentCreateResult {
        onProgress?(.createResolvingRuntime)
        guard let root = await siteDirectory(siteID) else { return .siteNotFound }
        guard let descriptor = registry.descriptor(id: typeID) else {
            return .failed(reason: "Unknown content type: \(typeID)")
        }
        guard let collection = descriptor.collection else {
            return .failed(reason: "\(typeID) is not a collection type; use createTypedSingleton")
        }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSlug = (slug ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let finalSlug = ContentScaffold.slugify(cleanSlug.isEmpty ? (cleanTitle.isEmpty ? descriptor.id : cleanTitle) : cleanSlug)
        guard !finalSlug.isEmpty else { return .failed(reason: "createTyped could not derive a slug") }

        let relPath = ContentScaffold.postRelativePath(collection: collection, slug: finalSlug)
        let abs = root.appendingPathComponent(relPath)
        if fileManager.fileExists(atPath: abs.path) {
            return .failed(reason: "A \(collection) entry already exists at \(relPath)")
        }

        // No `.createCallingPlugin` here: this is a native Swift write with no plugin involved.
        // `.createFinalizing` (below) covers the write + commit milestone honestly.
        let contents = ContentScaffold.renderEntry(
            descriptor: descriptor, title: cleanTitle.isEmpty ? nil : cleanTitle, now: now())
        do { try write(contents, to: abs) }
        catch { return .failed(reason: "\(error)") }

        onProgress?(.createFinalizing)
        _ = await gitCommit(root, relPath, "anglesite: add \(collection) \(finalSlug)")
        return .created(filePath: relPath, identifier: finalSlug)
    }

    /// Create a per-site singleton (V-1.3 follow-up, #388) — e.g. the representative h-card.
    /// Looks the type up, resolves its `singletonSlot`, renders the JSON data module via
    /// `ContentScaffold.renderSingleton`, and writes it — refusing if the slot file already exists,
    /// which enforces one identity per site across both `businessProfile` and `personalProfile`
    /// (they share the `"profile"` slot). Same write/commit path as `createTyped`.
    ///
    /// TODO: add to the `ContentOperationsService` protocol when remote runtimes land
    /// (`RemoteSandboxSiteRuntime` #66, `LocalContainerSiteRuntime` #69) — they implement the
    /// protocol and currently have no path to create singletons.
    public func createTypedSingleton(
        siteID: String,
        typeID: String,
        name: String,
        registry: ContentTypeRegistry = ContentTypeRegistry(),
        onProgress: ProgressHandler? = nil
    ) async -> ContentCreateResult {
        onProgress?(.createResolvingRuntime)
        guard let root = await siteDirectory(siteID) else { return .siteNotFound }
        guard let descriptor = registry.descriptor(id: typeID) else {
            return .failed(reason: "Unknown content type: \(typeID)")
        }
        guard let slot = descriptor.singletonSlot else {
            return .failed(reason: "\(typeID) is not a singleton type")
        }

        let relPath = ContentScaffold.singletonRelativePath(slot: slot)
        let abs = root.appendingPathComponent(relPath)
        // The exists-check → write below is a TOCTOU window (as it is in the sibling create*
        // methods). Acceptable here: the app is single-user and the create path is serialized, so
        // two concurrent calls for the same site don't occur in practice. If that assumption ever
        // changes, make this atomic with an O_CREAT|O_EXCL create rather than this check.
        if fileManager.fileExists(atPath: abs.path) {
            return .failed(reason: "A site identity already exists at \(relPath)")
        }

        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let contents = ContentScaffold.renderSingleton(
            descriptor: descriptor, name: cleanName.isEmpty ? nil : cleanName)
        do { try write(contents, to: abs) }
        catch { return .failed(reason: "\(error)") }

        onProgress?(.createFinalizing)
        _ = await gitCommit(root, relPath, "anglesite: add \(descriptor.id)")
        return .created(filePath: relPath, identifier: slot)
    }

    /// Delete a page/post/component file: `git rm` + commit via the injected `gitDelete` closure
    /// (default `processGitDelete`). No Trash involved — git history is the sole undo mechanism,
    /// matching `ProjectCleanupModel.delete`'s existing precedent for dead-asset deletion.
    public func deleteContent(siteID: String, relativePath: String) async -> ContentDeleteResult {
        guard let root = await siteDirectory(siteID) else { return .siteNotFound }
        let abs = root.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: abs.path) else {
            return .failed(reason: "No file exists at \(relativePath)")
        }
        guard await gitDelete(root, relativePath, "anglesite: delete \(relativePath)") != nil else {
            return .failed(reason: "Couldn't delete \(relativePath). Check for uncommitted changes and try again.")
        }
        return .deleted(filePath: relativePath)
    }

    /// Duplicate an existing page: read its contents, retitle to `"<title> Copy"` (bumping to
    /// `"<title> Copy 2"`, `"<title> Copy 3"`… on route collision — which slugifies to the
    /// `-copy`/`-copy-2` file-name convention), write the new file, commit. Title rewrite reuses
    /// `PageTitleEditor` (same transform `NavigatorRenameService` uses for Rename); if the source
    /// has no editable title location, the contents are duplicated verbatim.
    public func duplicatePage(siteID: String, relativePath: String, title: String) async -> ContentCreateResult {
        guard let root = await siteDirectory(siteID) else { return .siteNotFound }
        let sourceAbs = root.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: sourceAbs.path) else {
            return .failed(reason: "No page exists at \(relativePath)")
        }
        let contents: String
        do { contents = try FileDocumentIO.load(sourceAbs, fileManager: fileManager).contents }
        catch { return .failed(reason: "\(error)") }

        let baseTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let copyTitle = baseTitle.isEmpty ? "Copy" : "\(baseTitle) Copy"
        var attempt = 1
        var route = ContentScaffold.normalizeRoute(ContentScaffold.slugify(copyTitle))
        var relPath = ContentScaffold.pageRelativePath(normalizedRoute: route)
        while attempt < 1000, fileManager.fileExists(atPath: root.appendingPathComponent(relPath).path) {
            attempt += 1
            route = ContentScaffold.normalizeRoute(ContentScaffold.slugify("\(copyTitle) \(attempt)"))
            relPath = ContentScaffold.pageRelativePath(normalizedRoute: route)
        }

        let ext = (relativePath as NSString).pathExtension
        let rewritten: String
        switch PageTitleEditor.rewrite(contents: contents, fileExtension: ext, newTitle: copyTitle) {
        case .success(let s): rewritten = s
        case .failure: rewritten = contents
        }

        do { try write(rewritten, to: root.appendingPathComponent(relPath)) }
        catch { return .failed(reason: "\(error)") }

        _ = await gitCommit(root, relPath, "anglesite: duplicate page \(route)")
        return .created(filePath: relPath, identifier: route)
    }

    /// Duplicate an existing post within the same `collection`. Same retitle/collision/commit
    /// shape as `duplicatePage`, but derives a slug (not a route) and writes via
    /// `ContentScaffold.postRelativePath`.
    public func duplicatePost(siteID: String, relativePath: String, collection: String, title: String) async -> ContentCreateResult {
        guard let root = await siteDirectory(siteID) else { return .siteNotFound }
        let sourceAbs = root.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: sourceAbs.path) else {
            return .failed(reason: "No \(collection) entry exists at \(relativePath)")
        }
        let contents: String
        do { contents = try FileDocumentIO.load(sourceAbs, fileManager: fileManager).contents }
        catch { return .failed(reason: "\(error)") }

        let baseTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let copyTitle = baseTitle.isEmpty ? "Copy" : "\(baseTitle) Copy"
        var attempt = 1
        var slug = ContentScaffold.slugify(copyTitle)
        var relPath = ContentScaffold.postRelativePath(collection: collection, slug: slug)
        while attempt < 1000, fileManager.fileExists(atPath: root.appendingPathComponent(relPath).path) {
            attempt += 1
            slug = ContentScaffold.slugify("\(copyTitle) \(attempt)")
            relPath = ContentScaffold.postRelativePath(collection: collection, slug: slug)
        }

        let ext = (relativePath as NSString).pathExtension
        let rewritten: String
        switch PageTitleEditor.rewrite(contents: contents, fileExtension: ext, newTitle: copyTitle) {
        case .success(let s): rewritten = s
        case .failure: rewritten = contents
        }

        do { try write(rewritten, to: root.appendingPathComponent(relPath)) }
        catch { return .failed(reason: "\(error)") }

        _ = await gitCommit(root, relPath, "anglesite: duplicate \(collection) \(slug)")
        return .created(filePath: relPath, identifier: slug)
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

    /// Stage-delete and commit exactly `relPath` on the current branch (`git rm` + `git commit`).
    /// Returns the new HEAD SHA, or nil on any failure (not a repo, dirty tree, rejecting hook,
    /// git missing, no HEAD copy) — best-effort, mirroring `processGitCommit`'s shape exactly.
    /// Git history is the sole undo/archive mechanism for this delete; there is no separate
    /// trash/archive path.
    @Sendable public static func processGitDelete(_ projectRoot: URL, _ relPath: String, _ message: String) async -> String? {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        func run(_ args: [String]) async -> ProcessSupervisor.RunResult? {
            let result = try? await ProcessSupervisor.shared.run(executable: git, arguments: args, currentDirectoryURL: projectRoot)
            guard let result, result.exitCode == 0 else { return nil }
            return result
        }
        guard await run(["rev-parse", "--git-dir"]) != nil else { return nil }
        // Require a HEAD copy before touching anything: if `git commit` fails after `git rm`
        // already succeeds, the only safe rollback is `git checkout HEAD -- relPath`, which needs
        // HEAD to actually have the file. A staged-but-never-committed file (`git add`ed, no
        // commit yet) would otherwise risk ending up gone from both the index and the working
        // tree with no way back — refusing up front is a clean, side-effect-free failure instead.
        guard await run(["cat-file", "-e", "HEAD:" + relPath]) != nil else { return nil }
        guard await run(["rm", "--", relPath]) != nil else { return nil }
        guard await run(["commit", "-m", message, "--", relPath]) != nil else {
            // `git rm` already removed the file from the index and working tree before the
            // commit failed (no identity configured, a rejecting pre-commit hook, etc.) —
            // restore both from HEAD so a failed delete never leaves the file gone without a
            // commit. Same "never a raw non-git-recoverable delete" safety property the happy
            // path relies on, applied to the failure path too.
            // This second failure (the rollback itself also failing) has no regression test: by
            // this point the `cat-file -e HEAD:relPath` guard above has already confirmed HEAD
            // has the file, so `checkout HEAD --` failing here means something environmental went
            // wrong between that check and this line (disk full, permissions revoked mid-flight)
            // — genuinely hard to construct reliably/portably in a test, and narrower than it
            // looks since the precondition above already rules out the most common cause (no HEAD
            // copy). Logged rather than silently swallowed so it's at least diagnosable if it
            // ever fires for real.
            let restored = await run(["checkout", "HEAD", "--", relPath])
            if restored == nil {
                await LogCenter.shared.append(
                    source: "dead-assets:delete", stream: .stderr,
                    text: "processGitDelete: commit failed for \(relPath) AND rollback (git checkout HEAD --) also failed — the file may be missing from disk with no commit recording its removal. Manual recovery may be needed in \(projectRoot.path).")
            }
            return nil
        }
        guard let head = await run(["rev-parse", "HEAD"]) else { return nil }
        return head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
