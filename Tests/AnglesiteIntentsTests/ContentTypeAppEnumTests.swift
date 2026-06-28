import Testing
import AppIntents
@testable import AnglesiteCore
@testable import AnglesiteIntents

extension AppIntentsTests {
    @Suite("ContentTypeAppEnum")
    struct ContentTypeAppEnumTests {

        @Test("enum cases match the registry's collection-backed type ids exactly, in order (drift guard)")
        func driftGuard() {
            // Ordered equality, not just set equality: the Shortcuts picker shows cases in
            // declaration order, so it must track the registry's registration order too.
            #expect(ContentTypeAppEnum.allCases.map(\.rawValue) == ContentTypeRegistry.default.collectionBackedTypeIDs)
        }

        @Test("every case has a non-empty display representation and resolves a non-empty collection")
        func displayAndCollection() {
            for kind in ContentTypeAppEnum.allCases {
                let title = ContentTypeAppEnum.caseDisplayRepresentations[kind]?.title
                #expect(title != nil)
                #expect(kind.collection?.isEmpty == false)
            }
            #expect(ContentTypeAppEnum.event.collection == "events")
        }
    }
}
