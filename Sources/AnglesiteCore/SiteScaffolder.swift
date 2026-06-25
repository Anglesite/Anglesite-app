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
        let fileName = packageFileName(for: draft)
        let parentURL = draft.saveDirectory ?? sitesRoot
        let packageURL = parentURL.appendingPathComponent(fileName, isDirectory: true)

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

        // 2b. git init in Source/ (non-fatal — coordinates with #68).
        do { try await gitInit(siteDir) }
        catch { emit(.warning(step: "copyingTemplate", message: "git init skipped: \(humanize(error))")) }

        // 3. Theme (non-fatal). Resolve the owner's chosen theme; fall back to the first available.
        emit(.applyingTheme)
        if let theme = resolvedTheme(for: draft) {
            do { try ThemeApplier.apply(theme, siteDirectory: siteDir, fileManager: fileManager) }
            catch { emit(.warning(step: "applyingTheme", message: humanize(error))) }
        } else {
            emit(.warning(step: "applyingTheme", message: "No themes available; left default look."))
        }

        // 4. Homepage (non-fatal)
        emit(.writingContent)
        let metadataDescription = draft.tagline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? draft.blurb
            : draft.tagline
        do { try HomepageWriter.write(headline: draft.headline, blurb: draft.blurb,
                                      tagline: metadataDescription, siteDirectory: siteDir, fileManager: fileManager) }
        catch { emit(.warning(step: "writingContent", message: humanize(error))) }

        var logoPublicPath: String?
        if let logo = draft.logoURL {
            do {
                logoPublicPath = try LogoAsset.install(from: logo, siteName: draft.name,
                                                       siteDirectory: siteDir, fileManager: fileManager)
            } catch {
                emit(.warning(step: "writingContent", message: "Logo not added: \(humanize(error))"))
            }
        }

        do { try appendSiteConfig(draft, logoPublicPath: logoPublicPath, metadataDescription: metadataDescription, siteDir: siteDir) }
        catch { emit(.warning(step: "writingContent", message: "Site metadata not written: \(humanize(error))")) }

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

    /// Append owner answers without clobbering existing lines (e.g. ANGLESITE_VERSION).
    private func appendSiteConfig(_ draft: NewSiteDraft, logoPublicPath: String?,
                                  metadataDescription: String, siteDir: URL) throws {
        var values: [(String, String)] = [
            ("SITE_NAME", draft.name),
            ("SITE_TYPE", draft.siteType.rawValue),
            ("DOMAIN_CHOICE", draft.domainChoice.rawValue),
        ]
        if draft.domainChoice == .transfer && !draft.domain.isEmpty { values.append(("DOMAIN", draft.domain)) }
        if draft.themeID == CustomTheme.id {
            values.append(contentsOf: [
                ("THEME", CustomTheme.id),
                ("COLOR_PRIMARY", draft.customPrimaryColor),
                ("COLOR_ACCENT", draft.customAccentColor),
            ])
        } else {
            values.append(("THEME", draft.themeID))
        }
        if !metadataDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values.append(("TAGLINE", metadataDescription))
        }
        if let logoPublicPath { values.append(("LOGO", logoPublicPath)) }
        try appendSiteConfigValues(values, siteDir: siteDir)
    }

    private func appendSiteConfigValues(_ values: [(String, String)], siteDir: URL) throws {
        let url = siteDir.appendingPathComponent(".site-config")
        let contentsExists = fileManager.fileExists(atPath: url.path)
        var contents = contentsExists ? try String(contentsOf: url, encoding: .utf8) : ""
        func setKey(_ key: String, _ value: String) {
            guard !contents.contains("\n\(key)=") && !contents.hasPrefix("\(key)=") else { return }
            if !contents.isEmpty && !contents.hasSuffix("\n") { contents += "\n" }
            contents += "\(key)=\(Self.safeConfigValue(value))\n"
        }
        for (key, value) in values { setKey(key, value) }
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func safeConfigValue(_ value: String) -> String {
        (value.components(separatedBy: .newlines).first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolvedTheme(for draft: NewSiteDraft) -> Theme? {
        if draft.themeID == CustomTheme.id {
            return CustomTheme.make(primary: draft.customPrimaryColor, accent: draft.customAccentColor)
        }
        return catalog.theme(id: draft.themeID) ?? catalog.themes.first
    }

    private func packageFileName(for draft: NewSiteDraft) -> String {
        let raw = draft.saveFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = raw.isEmpty ? "\(SiteSlug.derive(from: draft.name)).anglesite" : raw
        return base.hasSuffix(".anglesite") ? base : "\(base).anglesite"
    }

    private func humanize(_ error: Error) -> String { (error as NSError).localizedDescription }
}
