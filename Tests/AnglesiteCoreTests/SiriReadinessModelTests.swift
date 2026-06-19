// Tests/AnglesiteCoreTests/SiriReadinessModelTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

private struct StubProbe: ReadinessProbe {
    let id: String
    let finding: ReadinessFinding
    init(_ finding: ReadinessFinding) {
        self.id = finding.id
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

    @Test func recheck_cancelled_resetsIsChecking() async {
        // A cancelled run must clear the spinner — otherwise `isChecking` is stuck `true`
        // forever and the Re-check button stays permanently disabled.
        let model = SiriReadinessModel(probes: [StubProbe(makeFinding("a", .ok))])
        let task = model.recheck()
        task.cancel()
        await task.value
        #expect(model.isChecking == false)
    }

    @Test func recheck_rapidDouble_firstCancelled_endsNotChecking() async {
        // The second recheck cancels the first via `inFlight?.cancel()`. The superseded run must
        // not clobber the live one, and the final state must reflect the second run's commit.
        let model = SiriReadinessModel(probes: [StubProbe(makeFinding("a", .ok))])
        let first = model.recheck()
        let second = model.recheck()
        await first.value
        await second.value
        #expect(model.isChecking == false)
        #expect(model.findings.map(\.id) == ["a"])
    }
}
