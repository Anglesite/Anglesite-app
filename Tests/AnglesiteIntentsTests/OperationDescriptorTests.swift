import Testing
import Foundation
@testable import AnglesiteIntents

/// Data-level contract tests for the operation-descriptor registry (#235). These assert structure
/// and declared values only; behavioral agreement (routing, content mutation) lives in
/// `OperationDescriptorBehavioralTests`. See the spec for why confirmation and the three site-op
/// side-effects are value-asserted rather than behaviorally cross-checked.
extension AppIntentsTests {
    @Suite("OperationDescriptors")
    struct OperationDescriptorTests {
        @Test("every Siri-phrase intent has a descriptor (coverage anchor)")
        func coverage() {
            let described = Set(AnglesiteOperations.all.map(\.intentTypeName))
            #expect(AnglesiteShortcuts.phraseExposedIntentNames.isSubset(of: described))
        }

        @Test("phrase-exposed name list matches the shortcuts provider count (sync guard)")
        func anchorSync() {
            #expect(AnglesiteShortcuts.appShortcuts.count == AnglesiteShortcuts.phraseExposedIntentNames.count)
        }

        @Test("operationID and intentTypeName are each unique")
        func uniqueness() {
            let ids = AnglesiteOperations.all.map(\.operationID)
            #expect(Set(ids).count == ids.count)
            let names = AnglesiteOperations.all.map(\.intentTypeName)
            #expect(Set(names).count == names.count)
        }

        @Test("descriptor(forIntentTypeName:) resolves a known intent and returns nil otherwise")
        func lookup() {
            #expect(AnglesiteOperations.descriptor(forIntentTypeName: "DeploySiteIntent")?.operationID == "deploy-site")
            #expect(AnglesiteOperations.descriptor(forIntentTypeName: "NotAnIntent") == nil)
        }

        @Test("declared fields match the authoritative value table")
        func declaredFields() throws {
            struct Expected {
                let sideEffect: OperationSideEffect
                let requiresConfirmation: Bool
                let isCancellable: Bool
                let resultShape: OperationResult
            }
            let expected: [String: Expected] = [
                "deploy-site": .init(sideEffect: .publishes, requiresConfirmation: true, isCancellable: true, resultShape: .entity("SiteEntity")),
                "backup-site": .init(sideEffect: .modifiesContent, requiresConfirmation: false, isCancellable: true, resultShape: .entity("SiteEntity")),
                "audit-site": .init(sideEffect: .readOnly, requiresConfirmation: false, isCancellable: true, resultShape: .entity("SiteEntity")),
                "open-site": .init(sideEffect: .readOnly, requiresConfirmation: false, isCancellable: false, resultShape: .none),
                "search-content": .init(sideEffect: .readOnly, requiresConfirmation: false, isCancellable: false, resultShape: .entities("ContentMatchEntity")),
                "site-status": .init(sideEffect: .readOnly, requiresConfirmation: false, isCancellable: false, resultShape: .none),
                "preview-site": .init(sideEffect: .readOnly, requiresConfirmation: false, isCancellable: false, resultShape: .none),
                "add-page": .init(sideEffect: .createsContent, requiresConfirmation: false, isCancellable: true, resultShape: .entity("PageEntity")),
                "add-post": .init(sideEffect: .createsContent, requiresConfirmation: false, isCancellable: true, resultShape: .entity("PostEntity")),
                "edit-content": .init(sideEffect: .modifiesContent, requiresConfirmation: false, isCancellable: true, resultShape: .none),
            ]
            #expect(expected.count == AnglesiteOperations.all.count)
            for descriptor in AnglesiteOperations.all {
                let want = try #require(expected[descriptor.operationID], "no expectation for \(descriptor.operationID)")
                #expect(descriptor.sideEffect == want.sideEffect, "\(descriptor.operationID) sideEffect")
                #expect(descriptor.requiresConfirmation == want.requiresConfirmation, "\(descriptor.operationID) requiresConfirmation")
                #expect(descriptor.isCancellable == want.isCancellable, "\(descriptor.operationID) isCancellable")
                #expect(descriptor.resultShape == want.resultShape, "\(descriptor.operationID) resultShape")
            }
        }

        @Test("mcpToolName is nil for all current entries (forward-looking field)")
        func mcpToolNamesUnset() {
            #expect(AnglesiteOperations.all.allSatisfy { $0.mcpToolName == nil })
        }
    }
}
