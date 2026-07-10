// Tests/AnglesiteCoreTests/ThemeApplyWizardModelTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct ThemeApplyWizardModelTests {
    private func makeSite() throws -> AnglesitePackage {
        let packageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = packageRoot.appendingPathComponent("Source/src/styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        try ":root {\n  --color-primary: #000000;\n}\n".write(
            to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)
        return AnglesitePackage(url: packageRoot)
    }

    private var testCatalog: ThemeCatalog {
        ThemeCatalog(themes: [Theme(id: "warm", name: "Warm", blurb: "cozy", swatch: ["#a11", "#a22"],
                                    cssVars: ["color-primary": "#a11111", "color-accent": "#a22222"])])
    }

    @Test @MainActor func picksBuiltInFlowAndApplies() async throws {
        let package = try makeSite()
        let model = ThemeApplyWizardModel(catalog: testCatalog, businessType: "bakery", package: package)
        model.source = .builtIn
        await model.advance() // pickSource -> pickBuiltIn
        #expect(model.step == .pickBuiltIn)
        model.selectedBuiltInID = "warm"
        await model.advance() // pickBuiltIn -> review
        #expect(model.step == .review)
        #expect(model.canContinue)
        await model.apply()
        #expect(model.step == .applying)
        guard case .success(let applied) = model.applyResult else { Issue.record("expected success"); return }
        #expect(applied.updatedVars["color-primary"] == "#a11111")
    }

    @Test @MainActor func canContinueRequiresSourceChoiceFirst() {
        let model = ThemeApplyWizardModel(catalog: testCatalog, businessType: "bakery",
                                          package: AnglesitePackage(url: FileManager.default.temporaryDirectory))
        #expect(model.canContinue == false)
        model.source = .builtIn
        #expect(model.canContinue)
    }

    @Test @MainActor func canContinueRequiresBuiltInSelection() async {
        let model = ThemeApplyWizardModel(catalog: testCatalog, businessType: "bakery",
                                          package: AnglesitePackage(url: FileManager.default.temporaryDirectory))
        model.source = .builtIn
        await model.advance()
        #expect(model.canContinue == false)
        model.selectedBuiltInID = "warm"
        #expect(model.canContinue)
    }

    @Test @MainActor func backReturnsToPickSource() async {
        let model = ThemeApplyWizardModel(catalog: testCatalog, businessType: "bakery",
                                          package: AnglesitePackage(url: FileManager.default.temporaryDirectory))
        model.source = .builtIn
        await model.advance()
        model.back()
        #expect(model.step == .pickSource)
    }
}
