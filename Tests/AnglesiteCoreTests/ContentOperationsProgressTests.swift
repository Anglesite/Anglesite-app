// Tests/AnglesiteCoreTests/ContentOperationsProgressTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite(.serialized)
struct ContentOperationsProgressTests {
    @Test("an unknown site emits resolvingRuntime then returns siteNotFound")
    func unknownSite() async {
        let recorder = ProgressRecorder()
        let ops = ContentOperations(pool: HeadlessRuntimePool(), siteDirectory: { _ in nil })
        let result = await ops.createPage(siteID: "ghost", name: "About", route: nil,
                                          onProgress: { recorder.record($0) })
        #expect(result == .siteNotFound)
        #expect(await recorder.phases().first == "resolvingRuntime")
    }
}
