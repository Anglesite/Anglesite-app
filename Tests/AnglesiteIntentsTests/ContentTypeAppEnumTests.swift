import Testing
import AppIntents
@testable import AnglesiteCore
@testable import AnglesiteIntents

extension AppIntentsTests {
    @Suite("ContentTypeAppEnum")
    struct ContentTypeAppEnumTests {

        @Test("enum cases match the registry's collection-backed type ids exactly (drift guard)")
        func driftGuard() {
            let enumIDs = Set(ContentTypeAppEnum.allCases.map(\.rawValue))
            let registryIDs = Set(ContentTypeRegistry.default.collectionBackedTypeIDs)
            #expect(enumIDs == registryIDs)
        }

        @Test("every case has a non-empty display representation and resolves its collection")
        func displayAndCollection() {
            for kind in ContentTypeAppEnum.allCases {
                let title = ContentTypeAppEnum.caseDisplayRepresentations[kind]?.title
                #expect(title != nil)
                #expect(kind.collection != nil)
            }
            #expect(ContentTypeAppEnum.event.collection == "events")
        }
    }
}
