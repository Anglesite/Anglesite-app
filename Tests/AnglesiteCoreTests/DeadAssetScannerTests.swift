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
}
