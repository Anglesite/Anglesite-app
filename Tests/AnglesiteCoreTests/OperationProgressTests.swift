// Tests/AnglesiteCoreTests/OperationProgressTests.swift
import Testing
@testable import AnglesiteCore

@Suite("OperationProgress")
struct OperationProgressTests {
    @Test("static milestones carry the expected kind and phase")
    func milestones() {
        #expect(OperationProgress.deployBuilding.kind == .deploy)
        #expect(OperationProgress.deployBuilding.phase == "building")
        #expect(OperationProgress.backupPushing.kind == .backup)
        #expect(OperationProgress.auditFinalizing.phase == "finalizing")
        #expect(OperationProgress.createCallingPlugin.kind == .createContent)
        #expect(OperationProgress.editApplying.kind == .edit)
    }

    @Test("auditRunning computes a determinate fraction")
    func auditFraction() {
        let p = OperationProgress.auditRunning(category: "accessibility", index: 0, of: 2)
        #expect(p.kind == .audit)
        #expect(p.phase == "running")
        #expect(p.fraction == 0.5)
        #expect(p.label.contains("accessibility"))
    }

    @Test("zero runners yields a nil fraction rather than dividing by zero")
    func auditFractionZero() {
        #expect(OperationProgress.auditRunning(category: "x", index: 0, of: 0).fraction == nil)
    }
}
