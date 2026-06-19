import AppIntents
import Testing
@testable import AnglesiteIntents

@Suite("SchemaConformance")
struct SchemaConformanceTests {
    @Test func siteEntityCarriesWordProcessorDocumentSchema() {
        #expect(SiteEntity.__appSchemaEntity == "wordProcessor.document")
        // `__appSchemaEntity` is macro-internal; also guard the public conformance the schema relies on.
        #expect((SiteEntity.self as Any.Type) is any AssistantSchemaEntity.Type)
    }
}
