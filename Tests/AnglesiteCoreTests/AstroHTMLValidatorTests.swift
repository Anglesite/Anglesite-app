import Foundation
import Testing
@testable import AnglesiteCore

@Suite("AstroHTMLValidator")
struct AstroHTMLValidatorTests {
    @Test("empty custom analytics HTML is valid without spawning Node")
    func emptyHTMLDoesNotSpawnNode() async {
        let validator = AstroHTMLValidator(
            nodeExecutable: { URL(fileURLWithPath: "/usr/bin/node") },
            run: { _, _, _ in
                Issue.record("Empty HTML should not run Astro validation")
                return ProcessSupervisor.RunResult(stdout: "", stderr: "", exitCode: 1)
            }
        )

        let message = await validator.validationMessage(for: "   \n", siteDirectory: URL(fileURLWithPath: "/tmp/site"))

        #expect(message == nil)
    }

    @Test("missing Astro compiler reports dependency error")
    func missingAstroCompiler() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let validator = AstroHTMLValidator(nodeExecutable: { URL(fileURLWithPath: "/usr/bin/node") })

        let message = await validator.validationMessage(for: "<script></script>", siteDirectory: root)

        #expect(message?.contains("Astro dependencies are missing") == true)
    }

    @Test("default validator reports container requirement when Astro deps exist")
    func defaultValidatorReportsContainerRequirement() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(
            at: root.appendingPathComponent("node_modules/@astrojs/compiler", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "{}".write(
            to: root.appendingPathComponent("node_modules/@astrojs/compiler/package.json"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fm.removeItem(at: root) }

        let message = await AstroHTMLValidator().validationMessage(for: "<script></script>", siteDirectory: root)

        #expect(message == "Custom analytics HTML validation must run in the container runtime; host Node has been retired.")
    }

    @Test("runner failure is returned as invalid custom analytics HTML")
    func runnerFailure() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(
            at: root.appendingPathComponent("node_modules/@astrojs/compiler", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "{}".write(
            to: root.appendingPathComponent("node_modules/@astrojs/compiler/package.json"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fm.removeItem(at: root) }

        let validator = AstroHTMLValidator(
            nodeExecutable: { URL(fileURLWithPath: "/usr/bin/node") },
            run: { _, arguments, cwd in
                #expect(arguments.count == 3)
                #expect(cwd == root)
                #expect((try? String(contentsOf: URL(fileURLWithPath: arguments[2]), encoding: .utf8)) == "<script></")
                return ProcessSupervisor.RunResult(
                    stdout: "",
                    stderr: "Cannot read properties of undefined (reading 'map')",
                    exitCode: 1
                )
            }
        )

        let message = await validator.validationMessage(for: "<script></", siteDirectory: root)

        #expect(message == "Custom analytics HTML is invalid: Astro couldn't parse the snippet. Check for incomplete tags or script blocks.")
    }
}
