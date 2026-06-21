import Foundation

/// Runs the deterministic new-site pipeline and emits progress. No Claude. Every subprocess
/// goes through the injected `CommandRunner` (production: `ProcessSupervisor.shared.run`).
public actor SiteScaffolder {

    public enum ScaffoldStep: Sendable, Equatable {
        case creatingFolder, copyingTemplate, applyingTheme, writingContent, installing, registering
        case warning(step: String, message: String)
        case failed(step: String, message: String)
        case done(siteID: String)
    }

    /// Run a command, return its result. cwd may be nil.
    public typealias CommandRunner = @Sendable (_ executable: URL, _ args: [String], _ cwd: URL?) async throws -> ProcessSupervisor.RunResult
    /// Register a freshly-scaffolded package and return the Site (production: SiteStore.shared.record).
    public typealias Register = @Sendable (_ package: AnglesitePackage) async throws -> SiteStore.Site
    /// Initialize a git repo in the source dir (production: `git init` via ProcessSupervisor).
    public typealias GitInit = @Sendable (_ sourceDirectory: URL) async throws -> Void

    private let sitesRoot: URL
    private let templateURL: URL
    private let catalog: ThemeCatalog
    private let run: CommandRunner
    private let gitInit: GitInit
    private let register: Register
    private let fileManager: FileManager

    /// `catalog` (not a fixed theme) so the owner's Look-step choice resolves at pipeline time
    /// from `draft.themeID`.
    public init(sitesRoot: URL, templateURL: URL, catalog: ThemeCatalog,
                run: @escaping CommandRunner, gitInit: @escaping GitInit,
                register: @escaping Register, fileManager: FileManager = .default) {
        self.sitesRoot = sitesRoot
        self.templateURL = templateURL
        self.catalog = catalog
        self.run = run
        self.gitInit = gitInit
        self.register = register
        self.fileManager = fileManager
    }

    public nonisolated func scaffold(_ draft: NewSiteDraft) -> AsyncStream<ScaffoldStep> {
        AsyncStream<ScaffoldStep>(bufferingPolicy: .unbounded) { continuation in
            Task {
                await self.runPipeline(draft) { step in continuation.yield(step) }
                continuation.finish()
            }
        }
    }

    private func runPipeline(_ draft: NewSiteDraft, emit: @Sendable (ScaffoldStep) -> Void) async {
        let slug = SiteSlug.derive(from: draft.name)
        let packageURL = sitesRoot.appendingPathComponent("\(slug).anglesite", isDirectory: true)

        // 1. Package skeleton (dir + Source/ + Config/ + Info.plist marker).
        emit(.creatingFolder)
        let package: AnglesitePackage
        do {
            (package, _) = try AnglesitePackage.createSkeleton(at: packageURL, displayName: draft.name, fileManager: fileManager)
        } catch { return emit(.failed(step: "creatingFolder", message: humanize(error))) }
        let siteDir = package.sourceURL   // everything below runs in Source/

        // 2. scaffold.sh (cwd = Source/)
        emit(.copyingTemplate)
        let scaffoldScript = templateURL.appendingPathComponent("scripts/scaffold.sh")
        do {
            let r = try await run(URL(fileURLWithPath: "/bin/zsh"),
                                  [scaffoldScript.path, "--yes", siteDir.path], siteDir)
            if r.exitCode != 0 {
                return emit(.failed(step: "copyingTemplate", message: "Couldn't create the site files.\n\(r.stderr)"))
            }
        } catch { return emit(.failed(step: "copyingTemplate", message: humanize(error))) }

        // 2b. Owner answers into .site-config (in Source/).
        do { try appendSiteConfig(draft, siteDir: siteDir) }
        catch { emit(.warning(step: "copyingTemplate", message: humanize(error))) }

        // 2c. git init in Source/ (non-fatal — coordinates with #68).
        do { try await gitInit(siteDir) }
        catch { emit(.warning(step: "copyingTemplate", message: "git init skipped: \(humanize(error))")) }

        // 3. Theme (non-fatal). Resolve the owner's chosen theme; fall back to the first available.
        emit(.applyingTheme)
        if let theme = catalog.theme(id: draft.themeID) ?? catalog.themes.first {
            do { try ThemeApplier.apply(theme, siteDirectory: siteDir, fileManager: fileManager) }
            catch { emit(.warning(step: "applyingTheme", message: humanize(error))) }
        } else {
            emit(.warning(step: "applyingTheme", message: "No themes available; left default look."))
        }

        // 4. Homepage (non-fatal)
        emit(.writingContent)
        do { try HomepageWriter.write(headline: draft.headline, blurb: draft.blurb,
                                      tagline: draft.tagline, siteDirectory: siteDir, fileManager: fileManager) }
        catch { emit(.warning(step: "writingContent", message: humanize(error))) }

        // 4b. Optional hero image (Image Playground, #92) — non-blocking. Only when the owner
        // generated one in the wizard; copies it into public/ and references it from the homepage.
        if let hero = draft.heroImageURL {
            do {
                try HeroImage.install(from: hero, headline: draft.headline, siteName: draft.name,
                                      siteDirectory: siteDir, fileManager: fileManager)
            } catch {
                emit(.warning(step: "writingContent", message: "Hero image not added: \(humanize(error))"))
            }
        }

        // 5. npm install (cwd = Source/, non-fatal — site still opens with the deps-not-installed preview state)
        emit(.installing)
        if let node = NodeRuntime.bundledExecutableURL {
            let npm = node.deletingLastPathComponent().appendingPathComponent("npm")
            do {
                let r = try await run(node, [npm.path] + NodeModulesCache.shared.npmInstallArguments(), siteDir)
                if r.exitCode != 0 {
                    emit(.warning(step: "installing", message: "Dependencies didn't install — you can retry from the site window.\n\(r.stderr)"))
                }
            } catch { emit(.warning(step: "installing", message: humanize(error))) }
        } else {
            emit(.warning(step: "installing", message: "Bundled Node not found; skipped install."))
        }

        // 6. Register the package
        emit(.registering)
        do {
            let site = try await register(package)
            emit(.done(siteID: site.id))
        } catch { emit(.failed(step: "registering", message: humanize(error))) }
    }

    /// Append SITE_NAME / SITE_TYPE / TAGLINE without clobbering existing lines (e.g. ANGLESITE_VERSION).
    private func appendSiteConfig(_ draft: NewSiteDraft, siteDir: URL) throws {
        let url = siteDir.appendingPathComponent(".site-config")
        var contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        func setKey(_ key: String, _ value: String) {
            guard !contents.contains("\n\(key)=") && !contents.hasPrefix("\(key)=") else { return }
            if !contents.isEmpty && !contents.hasSuffix("\n") { contents += "\n" }
            contents += "\(key)=\(value)\n"
        }
        setKey("SITE_NAME", draft.name)
        setKey("SITE_TYPE", draft.siteType.rawValue)
        if !draft.tagline.isEmpty { setKey("TAGLINE", draft.tagline) }
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func humanize(_ error: Error) -> String { (error as NSError).localizedDescription }
}
