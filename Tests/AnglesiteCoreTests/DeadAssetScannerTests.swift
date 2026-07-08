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
