// Tests/AnglesiteCoreTests/SiriReadinessModelTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

private struct StubProbe: ReadinessProbe {
    let id: String
    let title: String
    let finding: ReadinessFinding
    init(_ finding: ReadinessFinding) {
        self.id = finding.id
        self.title = finding.title
        self.finding = finding
    }
    func check() async -> ReadinessFinding { finding }
}

private func makeFinding(_ id: String, _ level: ReadinessLevel) -> ReadinessFinding {
    ReadinessFinding(id: id, title: id, level: level, detail: "detail")
}

@MainActor
@Suite struct SiriReadinessModelTests {
    @Test func initialState_isEmpty() {
        let model = SiriReadinessModel(probes: [])
        #expect(model.findings.isEmpty)
        #expect(model.isChecking == false)
        #expect(model.lastChecked == nil)
    }

    @Test func recheck_collectsFindingsInOrder_andStampsTime() async {
        let stamp = Date(timeIntervalSince1970: 1000)
        let model = SiriReadinessModel(
            probes: [StubProbe(makeFinding("a", .ok)), StubProbe(makeFinding("b", .warning))],
            now: { stamp }
        )
        await model.recheck().value
        #expect(model.findings.map(\.id) == ["a", "b"])
        #expect(model.isChecking == false)
        #expect(model.lastChecked == stamp)
    }

    @Test func overallLevel_failureWins() async {
        let model = SiriReadinessModel(probes: [
            StubProbe(makeFinding("a", .ok)),
            StubProbe(makeFinding("b", .warning)),
            StubProbe(makeFinding("c", .failure)),
        ])
        await model.recheck().value
        #expect(model.overallLevel == .failure)
    }

    @Test func overallLevel_allUnsupported_isUnsupported() async {
        let model = SiriReadinessModel(probes: [StubProbe(makeFinding("a", .unsupported))])
        await model.recheck().value
        #expect(model.overallLevel == .unsupported)
    }

    @Test func overallLevel_mixOkAndUnsupported_isOk() async {
        let model = SiriReadinessModel(probes: [
            StubProbe(makeFinding("a", .ok)),
            StubProbe(makeFinding("b", .unsupported)),
        ])
        await model.recheck().value
        #expect(model.overallLevel == .ok)
    }
}
