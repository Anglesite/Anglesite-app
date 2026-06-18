import Testing
@testable import AnglesiteIntents

/// Verifies that `SiteEntity` carries the `.wordProcessor.document` AppSchema annotation,
/// which enables Siri / Spotlight to recognise sites as document containers.
@Suite("SchemaConformance")
struct SchemaConformanceTests {
    @Test func siteEntityCarriesWordProcessorDocumentSchema() {
        #expect(SiteEntity.__appSchemaEntity == "wordProcessor.document")
    }
}
