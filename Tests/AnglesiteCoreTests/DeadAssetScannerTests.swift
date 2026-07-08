import Foundation
import Testing
@testable import AnglesiteCore

@Suite("DeadAssetScanner reference extraction")
struct DeadAssetScannerExtractionTests {

    @Test("extracts import statements and resolves relative paths against the source file's directory")
    func importResolution() {
        let source = """
        ---
        import Header from '../components/Header.astro';
        ---
        <Header />
        """
        let refs = DeadAssetScanner.extractReferences(source: source, path: "src/pages/about.astro")
        #expect(refs.fileReferences.contains("src/components/Header.astro"))
    }

    @Test("extracts href/src attributes and resolves an absolute path against public/")
    func absolutePathResolution() {
        let source = #"<img src="/images/hero.png" alt="hero">"#
        let refs = DeadAssetScanner.extractReferences(source: source, path: "src/pages/index.astro")
        #expect(refs.fileReferences.contains("public/images/hero.png"))
    }

    @Test("extracts markdown image references")
    func markdownImageResolution() {
        let source = "![alt](../../../public/images/photo.jpg)"
        let refs = DeadAssetScanner.extractReferences(source: source, path: "src/content/posts/entry.md")
        #expect(refs.fileReferences.contains("public/images/photo.jpg"))
    }

    @Test("extracts CSS url() references")
    func cssURLResolution() {
        let source = "@font-face { src: url('../fonts/brand.woff2'); }"
        let refs = DeadAssetScanner.extractReferences(source: source, path: "src/styles/global.css")
        #expect(refs.fileReferences.contains("src/fonts/brand.woff2"))
    }

    @Test("Astro.glob marks the resolved directory, not an exact file")
    func globDirectory() {
        let source = "const posts = await Astro.glob('../content/*.md');"
        let refs = DeadAssetScanner.extractReferences(source: source, path: "src/pages/blog.astro")
        #expect(refs.globDirectories.contains("src/content"))
    }

    @Test("bare/unresolvable specifiers are never counted as references")
    func unresolvableSpecifiersSkipped() {
        let source = """
        ---
        import { getCollection } from 'astro:content';
        import Foo from '@components/Foo.astro';
        ---
        """
        let refs = DeadAssetScanner.extractReferences(source: source, path: "src/pages/index.astro")
        #expect(refs.fileReferences.isEmpty)
    }

    @Test("relative path resolution walks up directories for each ..")
    func relativeResolutionWalksUp() {
        let source = "import Base from '../../layouts/Base.astro';"
        let refs = DeadAssetScanner.extractReferences(source: source, path: "src/components/cards/Card.astro")
        #expect(refs.fileReferences.contains("src/layouts/Base.astro"))
    }

    @Test("glob pattern with no subdirectory (./*.astro) resolves to the source file's own directory")
    func globSameDirectory() {
        let source = "const modules = import.meta.glob('./*.astro');"
        let refs = DeadAssetScanner.extractReferences(source: source, path: "src/pages/blog.astro")
        #expect(refs.globDirectories.contains("src/pages"))
    }

    @Test("glob pattern with parent-directory-only (../*.astro) resolves to the parent directory")
    func globParentDirectoryOnly() {
        let source = "const modules = import.meta.glob('../*.astro');"
        let refs = DeadAssetScanner.extractReferences(source: source, path: "src/pages/nested/blog.astro")
        #expect(refs.globDirectories.contains("src/pages"))
    }
}

@Suite("DeadAssetScanner full scan")
struct DeadAssetScannerScanTests {
    private func makeSite(_ files: [String: String]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dead-asset-scan-\(UUID().uuidString)", isDirectory: true)
        for (rel, contents) in files {
            let url = root.appendingPathComponent(rel)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(contents.utf8).write(to: url)
        }
        return root
    }

    @Test("dead component is flagged, imported component is not")
    func componentDetection() {
        let root = makeSite([
            "src/pages/index.astro": "---\nimport Header from '../components/Header.astro';\n---\n<Header />",
            "src/components/Header.astro": "<header>Site</header>",
            "src/components/Orphan.astro": "<div>never imported</div>",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        let paths = Set(candidates.map(\.path))
        #expect(paths.contains("src/components/Orphan.astro"))
        #expect(!paths.contains("src/components/Header.astro"))
    }

    @Test("layout referenced only via frontmatter is not flagged")
    func layoutFrontmatterReference() {
        let root = makeSite([
            "src/content/posts/hello.md": "---\ntitle: Hello\nlayout: ../../layouts/Post.astro\n---\nBody",
            "src/layouts/Post.astro": "<slot />",
            "src/layouts/Unused.astro": "<slot />",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        let paths = Set(candidates.map(\.path))
        #expect(!paths.contains("src/layouts/Post.astro"))
        #expect(paths.contains("src/layouts/Unused.astro"))
    }

    @Test("Astro.glob-covered directory suppresses false positives for every file inside it")
    func globCoveredDirectory() {
        let root = makeSite([
            "src/pages/index.astro": "---\nconst widgets = await Astro.glob('../components/widgets/*.astro');\n---\n<div></div>",
            "src/components/widgets/Card.astro": "<div>card</div>",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        #expect(!candidates.map(\.path).contains("src/components/widgets/Card.astro"))
    }

    @Test("unused image (public path) is flagged; referenced image is not")
    func imageDetection() {
        let root = makeSite([
            "src/pages/index.astro": #"<img src="/images/hero.png">"#,
        ])
        let images = [
            SiteContentGraph.Image(
                id: "s:image:public/images/hero.png", siteID: "s",
                relativePath: "public/images/hero.png", fileName: "hero.png",
                byteSize: nil, usedOnPages: [], lastModified: Date(timeIntervalSince1970: 0)),
            SiteContentGraph.Image(
                id: "s:image:public/images/unused.png", siteID: "s",
                relativePath: "public/images/unused.png", fileName: "unused.png",
                byteSize: nil, usedOnPages: [], lastModified: Date(timeIntervalSince1970: 0)),
        ]
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: images)
        let paths = Set(candidates.map(\.path))
        #expect(paths.contains("public/images/unused.png"))
        #expect(!paths.contains("public/images/hero.png"))
    }

    @Test("empty project produces no candidates")
    func emptyProject() {
        let root = makeSite([:])
        #expect(DeadAssetScanner.scan(projectRoot: root, images: []).isEmpty)
    }

    @Test("path alias from tsconfig.json paths resolves to the real file, suppressing a false-unused flag")
    func tsconfigPathAlias() {
        let root = makeSite([
            "tsconfig.json": #"{"compilerOptions": {"paths": {"@components/*": ["src/components/*"]}}}"#,
            "src/pages/index.astro": "---\nimport Header from '@components/Header.astro';\n---\n<Header />",
            "src/components/Header.astro": "<header>Site</header>",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        #expect(!candidates.map(\.path).contains("src/components/Header.astro"))
    }

    @Test("KNOWN LIMITATION: an alias with no matching tsconfig/jsconfig paths entry (e.g. vite.resolve.alias in astro.config.mjs) still produces a false-positive unused flag")
    func aliasWithNoPathsEntryIsNotResolved() {
        let root = makeSite([
            "src/pages/index.astro": "---\nimport Header from '@components/Header.astro';\n---\n<Header />",
            "src/components/Header.astro": "<header>Site</header>",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        #expect(candidates.map(\.path).contains("src/components/Header.astro"))
    }

    @Test("baseUrl-relative path alias resolves to the real file")
    func tsconfigBaseURLAlias() {
        let root = makeSite([
            "tsconfig.json": #"{"compilerOptions": {"baseUrl": "./src", "paths": {"@components/*": ["components/*"]}}}"#,
            "src/pages/index.astro": "---\nimport Header from '@components/Header.astro';\n---\n<Header />",
            "src/components/Header.astro": "<header>Site</header>",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        #expect(!candidates.map(\.path).contains("src/components/Header.astro"))
    }

    @Test("exact (non-wildcard) path alias resolves to the real file")
    func tsconfigExactAlias() {
        let root = makeSite([
            "tsconfig.json": #"{"compilerOptions": {"paths": {"@header": ["src/components/Header.astro"]}}}"#,
            "src/pages/index.astro": "---\nimport Header from '@header';\n---\n<Header />",
            "src/components/Header.astro": "<header>Site</header>",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        #expect(!candidates.map(\.path).contains("src/components/Header.astro"))
    }

    @Test("path alias inherited through an extends chain resolves to the real file")
    func tsconfigExtendsChain() {
        let root = makeSite([
            "tsconfig.base.json": #"{"compilerOptions": {"paths": {"@components/*": ["src/components/*"]}}}"#,
            "tsconfig.json": #"{"extends": "./tsconfig.base.json"}"#,
            "src/pages/index.astro": "---\nimport Header from '@components/Header.astro';\n---\n<Header />",
            "src/components/Header.astro": "<header>Site</header>",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        #expect(!candidates.map(\.path).contains("src/components/Header.astro"))
    }

    @Test("reference matching is case-insensitive (default APFS is case-insensitive-but-case-preserving)")
    func caseInsensitiveMatch() {
        let root = makeSite([
            "src/pages/index.astro": "---\nimport Header from '../components/header.astro';\n---\n<Header />",
            "src/components/Header.astro": "<header>Site</header>",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        #expect(!candidates.map(\.path).contains("src/components/Header.astro"))
    }

    @Test("multi-target path alias: a component under a later target is still resolved")
    func tsconfigMultiTargetAlias() {
        let root = makeSite([
            "tsconfig.json": #"{"compilerOptions": {"paths": {"@shared/*": ["src/nonexistent/*", "src/components/*"]}}}"#,
            "src/pages/index.astro": "---\nimport Header from '@shared/Header.astro';\n---\n<Header />",
            "src/components/Header.astro": "<header>Site</header>",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        #expect(!candidates.map(\.path).contains("src/components/Header.astro"))
    }

    @Test("import.meta.glob (array of patterns) marks the resolved directories, not exact files")
    func importMetaGlobDirectory() {
        let root = makeSite([
            "src/pages/index.astro": "---\nconst modules = import.meta.glob([\"../components/**/*.astro\", \"../layouts/**/*.astro\"]);\n---\n<div></div>",
            "src/components/Card.astro": "<div>card</div>",
            "src/layouts/Post.astro": "<slot />",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        let paths = Set(candidates.map(\.path))
        #expect(!paths.contains("src/components/Card.astro"))
        #expect(!paths.contains("src/layouts/Post.astro"))
    }

    @Test("import.meta.glob with a root-relative pattern (leading slash) resolves against the project root, not public/")
    func importMetaGlobRootRelative() {
        let root = makeSite([
            "src/pages/index.astro": "---\nconst modules = import.meta.glob(\"/src/components/**/*.astro\");\n---\n<div></div>",
            "src/components/Card.astro": "<div>card</div>",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        #expect(!candidates.map(\.path).contains("src/components/Card.astro"))
    }

    @Test("top-level scripts/ (dev-harness glob) is excluded from the reference scan")
    func scriptsDirectoryExcluded() {
        let root = makeSite([
            "scripts/harness/component.astro": "---\nconst modules = import.meta.glob([\"/src/components/**/*.astro\", \"/src/layouts/**/*.astro\"]);\n---\n<div></div>",
            "src/pages/index.astro": "<div>no imports here</div>",
            "src/components/Orphan.astro": "<div>never imported</div>",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        #expect(candidates.map(\.path).contains("src/components/Orphan.astro"))
    }

    @Test("a nested src/scripts/ directory (not the top-level dev-tooling one) is still scanned")
    func nestedScriptsDirectoryStillScanned() {
        let root = makeSite([
            "src/scripts/analytics.js": "import Icon from '../components/Icon.astro';",
            "src/components/Icon.astro": "<svg></svg>",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        #expect(!candidates.map(\.path).contains("src/components/Icon.astro"))
    }

    @Test("components referenced only from a .tsx file are not flagged as unused")
    func referencedFromTypeScriptFile() {
        let root = makeSite([
            "src/components/Icon.astro": "<svg></svg>",
            "src/widgets/Widget.tsx": "import Icon from '../components/Icon.astro';\nexport default function Widget() { return null; }",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        #expect(!candidates.map(\.path).contains("src/components/Icon.astro"))
    }

    @Test("images referenced only from a .jsx island's src attribute are not flagged as unused")
    func imageReferencedFromJSXIsland() {
        let root = makeSite([
            "src/islands/Hero.jsx": "export default function Hero() { return <img src=\"/images/hero.png\" />; }",
        ])
        let images = [
            SiteContentGraph.Image(
                id: "s:image:public/images/hero.png", siteID: "s",
                relativePath: "public/images/hero.png", fileName: "hero.png",
                byteSize: nil, usedOnPages: [], lastModified: Date(timeIntervalSince1970: 0)),
        ]
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: images)
        #expect(!candidates.map(\.path).contains("public/images/hero.png"))
    }

    @Test("layout: frontmatter alias resolves the same way body references do")
    func layoutFrontmatterAlias() {
        let root = makeSite([
            "tsconfig.json": #"{"compilerOptions": {"paths": {"@layouts/*": ["src/layouts/*"]}}}"#,
            "src/content/posts/hello.md": "---\ntitle: Hello\nlayout: @layouts/Post.astro\n---\nBody",
            "src/layouts/Post.astro": "<slot />",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        #expect(!candidates.map(\.path).contains("src/layouts/Post.astro"))
    }

    @Test("non-layout frontmatter fields (image:, cover:, gallery array) are scanned as references too")
    func frontmatterImageFieldsScanned() {
        let root = makeSite([
            "src/content/posts/hello.md": "---\ntitle: Hello\nimage: /images/cover.png\ngallery: [/images/one.png, /images/two.png]\n---\nBody",
        ])
        let images = ["cover.png", "one.png", "two.png", "unused.png"].map { name in
            SiteContentGraph.Image(
                id: "s:image:public/images/\(name)", siteID: "s",
                relativePath: "public/images/\(name)", fileName: name,
                byteSize: nil, usedOnPages: [], lastModified: Date(timeIntervalSince1970: 0))
        }
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: images)
        let paths = Set(candidates.map(\.path))
        #expect(!paths.contains("public/images/cover.png"))
        #expect(!paths.contains("public/images/one.png"))
        #expect(!paths.contains("public/images/two.png"))
        #expect(paths.contains("public/images/unused.png"))
    }

    @Test("overlapping alias patterns resolve deterministically to the more specific (longer literal prefix) one")
    func overlappingAliasPatternsPreferMoreSpecific() {
        let root = makeSite([
            "tsconfig.json": #"{"compilerOptions": {"paths": {"@/*": ["src/wrong/*"], "@/components/*": ["src/components/*"]}}}"#,
            "src/pages/index.astro": "---\nimport Header from '@/components/Header.astro';\n---\n<Header />",
            "src/components/Header.astro": "<header>Site</header>",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        // Both patterns match "@/components/Header.astro"; the general "@/*" would resolve to
        // src/wrong/components/Header.astro (a dead key that matches nothing), so this only
        // passes if the more specific "@/components/*" pattern's target is also tried.
        #expect(!candidates.map(\.path).contains("src/components/Header.astro"))
    }

    @Test("a same-directory glob pattern (./*.astro) suppresses false positives for files beside it")
    func globSameDirectorySuppressesCandidate() {
        let root = makeSite([
            "src/components/index.astro": "---\nconst modules = import.meta.glob('./*.astro');\n---\n<div></div>",
            "src/components/Card.astro": "<div>card</div>",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        #expect(!candidates.map(\.path).contains("src/components/Card.astro"))
    }

    @Test("top-level scripts/ exclusion is case-insensitive")
    func scriptsDirectoryExclusionCaseInsensitive() {
        let root = makeSite([
            "Scripts/harness/component.astro": "---\nconst modules = import.meta.glob([\"/src/components/**/*.astro\", \"/src/layouts/**/*.astro\"]);\n---\n<div></div>",
            "src/pages/index.astro": "<div>no imports here</div>",
            "src/components/Orphan.astro": "<div>never imported</div>",
        ])
        let candidates = DeadAssetScanner.scan(projectRoot: root, images: [])
        #expect(candidates.map(\.path).contains("src/components/Orphan.astro"))
    }
}
