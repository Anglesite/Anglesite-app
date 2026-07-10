// Tests/AnglesiteCoreTests/DesignApplyServiceTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct DesignApplyServiceTests {
    private func makeSite() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = dir.appendingPathComponent("src/styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        let css = """
        :root {
          --color-primary: #2563eb;
          --color-accent: #f59e0b;
          --font-heading: system-ui, -apple-system, sans-serif;
        }

        * { box-sizing: border-box; }
        """
        try css.write(to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func updatesExistingVarsInRootBlock() throws {
        let dir = try makeSite()
        let input = DesignApplyInput(cssVars: ["color-primary": "#ff0000"], rationaleMarkdown: nil,
                                     brandSummary: "A test brand.", sourceLabel: "Test")
        let result = DesignApplyService.apply(input, to: dir)
        guard case .success = result else { Issue.record("expected success"); return }
        let css = try String(contentsOf: dir.appendingPathComponent("src/styles/global.css"), encoding: .utf8)
        #expect(css.contains("--color-primary: #ff0000;"))
        #expect(css.contains("--color-accent: #f59e0b;")) // untouched var preserved
    }

    @Test func addsNewVarsNotPreviouslyInRootBlock() throws {
        let dir = try makeSite()
        let input = DesignApplyInput(cssVars: ["color-surface": "#eeeeee"], rationaleMarkdown: nil,
                                     brandSummary: "A test brand.", sourceLabel: "Test")
        _ = DesignApplyService.apply(input, to: dir)
        let css = try String(contentsOf: dir.appendingPathComponent("src/styles/global.css"), encoding: .utf8)
        #expect(css.contains("--color-surface: #eeeeee;"))
    }

    @Test func preservesEverythingOutsideRootBlock() throws {
        let dir = try makeSite()
        let input = DesignApplyInput(cssVars: ["color-primary": "#ff0000"], rationaleMarkdown: nil,
                                     brandSummary: "A test brand.", sourceLabel: "Test")
        _ = DesignApplyService.apply(input, to: dir)
        let css = try String(contentsOf: dir.appendingPathComponent("src/styles/global.css"), encoding: .utf8)
        #expect(css.contains("* { box-sizing: border-box; }"))
    }

    @Test func writesRationaleWhenProvided() throws {
        let dir = try makeSite()
        let input = DesignApplyInput(cssVars: [:], rationaleMarkdown: "# Design", brandSummary: "A test brand.", sourceLabel: "Test")
        let result = DesignApplyService.apply(input, to: dir)
        guard case .success(let applied) = result else { Issue.record("expected success"); return }
        #expect(applied.writtenFiles.contains("docs/DESIGN.md"))
        let md = try String(contentsOf: dir.appendingPathComponent("docs/DESIGN.md"), encoding: .utf8)
        #expect(md == "# Design")
    }

    @Test func skipsRationaleFileWhenNil() throws {
        let dir = try makeSite()
        let input = DesignApplyInput(cssVars: [:], rationaleMarkdown: nil, brandSummary: "A test brand.", sourceLabel: "Test")
        guard case .success(let applied) = DesignApplyService.apply(input, to: dir) else { Issue.record("expected success"); return }
        #expect(!applied.writtenFiles.contains("docs/DESIGN.md"))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("docs/DESIGN.md").path))
    }

    @Test func appendsBrandSummaryToNewBrandMd() throws {
        let dir = try makeSite()
        let input = DesignApplyInput(cssVars: [:], rationaleMarkdown: nil, brandSummary: "A test brand.", sourceLabel: "Built-in theme: Warm")
        _ = DesignApplyService.apply(input, to: dir)
        let brand = try String(contentsOf: dir.appendingPathComponent("docs/brand.md"), encoding: .utf8)
        #expect(brand.contains("Built-in theme: Warm"))
        #expect(brand.contains("A test brand."))
    }

    @Test func failsWhenGlobalCSSMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = DesignApplyInput(cssVars: ["color-primary": "#fff"], rationaleMarkdown: nil, brandSummary: "x", sourceLabel: "x")
        let result = DesignApplyService.apply(input, to: dir)
        guard case .failure(.missingGlobalCSS) = result else { Issue.record("expected .missingGlobalCSS"); return }
    }

    @Test func failsWithMissingRootBlockWhenGlobalCSSHasNoRoot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = dir.appendingPathComponent("src/styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        let css = "* { box-sizing: border-box; }\n"
        try css.write(to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)

        let input = DesignApplyInput(cssVars: ["color-primary": "#fff"], rationaleMarkdown: nil, brandSummary: "x", sourceLabel: "x")
        let result = DesignApplyService.apply(input, to: dir)
        guard case .failure(.missingRootBlock) = result else { Issue.record("expected .missingRootBlock"); return }
    }

    @Test func appendsBrandSummaryAcrossMultipleApplies() throws {
        let dir = try makeSite()
        let firstInput = DesignApplyInput(cssVars: [:], rationaleMarkdown: nil, brandSummary: "First brand summary.", sourceLabel: "Built-in theme: Warm")
        _ = DesignApplyService.apply(firstInput, to: dir)
        let secondInput = DesignApplyInput(cssVars: [:], rationaleMarkdown: nil, brandSummary: "Second brand summary.", sourceLabel: "Built-in theme: Cool")
        _ = DesignApplyService.apply(secondInput, to: dir)

        let brand = try String(contentsOf: dir.appendingPathComponent("docs/brand.md"), encoding: .utf8)
        #expect(brand.contains("Built-in theme: Warm"))
        #expect(brand.contains("First brand summary."))
        #expect(brand.contains("Built-in theme: Cool"))
        #expect(brand.contains("Second brand summary."))
    }

    /// A `FileManager` subclass that fails `createDirectory` once a target path matches a
    /// given substring, used to force a partial-write failure partway through `apply`.
    private final class FailingFileManager: FileManager, @unchecked Sendable {
        let failingPathSubstring: String

        init(failingPathSubstring: String) {
            self.failingPathSubstring = failingPathSubstring
            super.init()
        }

        override func createDirectory(
            at url: URL,
            withIntermediateDirectories createIntermediates: Bool,
            attributes: [FileAttributeKey: Any]? = nil
        ) throws {
            if url.path.contains(failingPathSubstring) {
                throw NSError(domain: "DesignApplyServiceTests", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "forced failure creating \(url.path)",
                ])
            }
            try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
        }
    }

    @Test func writeFailureAfterGlobalCSSReportsPartiallyWrittenFiles() throws {
        let dir = try makeSite()
        let failingManager = FailingFileManager(failingPathSubstring: "docs")
        let input = DesignApplyInput(cssVars: ["color-primary": "#ff0000"], rationaleMarkdown: nil,
                                     brandSummary: "A test brand.", sourceLabel: "Test")
        let result = DesignApplyService.apply(input, to: dir, fileManager: failingManager)

        guard case .failure(.writeFailed(_, let partiallyWritten)) = result else {
            Issue.record("expected .writeFailed"); return
        }
        #expect(partiallyWritten == ["src/styles/global.css"])

        // The CSS write itself succeeded on disk even though the overall apply failed.
        let css = try String(contentsOf: dir.appendingPathComponent("src/styles/global.css"), encoding: .utf8)
        #expect(css.contains("--color-primary: #ff0000;"))
    }
}

extension DesignApplyServiceTests {
    /// Builds a real `.anglesite` package layout: a package root containing a `Source/`
    /// subdirectory with the `src/styles/global.css` fixture nested underneath, matching
    /// `AnglesitePackage.sourceURL`'s real `url/Source` invariant (not a synthetic wrapper).
    private func makePackageRoot() throws -> URL {
        let packageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = packageRoot.appendingPathComponent("Source/src/styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        let css = """
        :root {
          --color-primary: #2563eb;
          --color-accent: #f59e0b;
          --font-heading: system-ui, -apple-system, sans-serif;
        }

        * { box-sizing: border-box; }
        """
        try css.write(to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)
        return packageRoot
    }

    @Test func packageOverloadDelegatesToSourceDirectory() throws {
        let packageRoot = try makePackageRoot()
        let package = AnglesitePackage(url: packageRoot)
        let input = DesignApplyInput(cssVars: ["color-primary": "#ff0000"], rationaleMarkdown: nil,
                                     brandSummary: "x", sourceLabel: "x")
        let result = DesignApplyService.apply(input, to: package)
        guard case .success = result else { Issue.record("expected success"); return }
        let css = try String(contentsOf: packageRoot.appendingPathComponent("Source/src/styles/global.css"), encoding: .utf8)
        #expect(css.contains("--color-primary: #ff0000;"))
    }
}
