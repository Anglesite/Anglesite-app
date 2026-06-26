// Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ContentTypeRegistry")
struct ContentTypeRegistryTests {

    // MARK: Registry mechanics

    @Test("default registry exposes the built-in catalog in order, looked up by id")
    func defaultRegistry() {
        let registry = ContentTypeRegistry()
        #expect(registry.all.map(\.id) == registry.ids)
        #expect(registry.ids == ContentTypeRegistry.builtIns.map(\.id))
        #expect(registry.descriptor(id: "note") != nil)
        #expect(registry.descriptor(id: "businessProfile") != nil)
        #expect(registry.descriptor(id: "nope") == nil)
    }

    @Test("registering a new type appends; the registry surfaces it by id")
    func registerAppends() {
        var registry = ContentTypeRegistry(types: [])
        #expect(registry.all.isEmpty)
        let custom = ContentTypeDescriptor(
            id: "recipe",
            displayName: "Recipe",
            storage: .collection("recipes"),
            fields: [ContentTypeField("title", .string, required: true)],
            projections: ContentTypeProjections(
                microformat: "h-recipe",
                microformatProperties: ["title": "p-name"],
                schemaType: "Recipe"
            )
        )
        registry.register(custom)
        #expect(registry.ids == ["recipe"])
        #expect(registry.descriptor(id: "recipe") == custom)
    }

    @Test("re-registering an id replaces in place and keeps its position")
    func registerReplacesInPlace() throws {
        var registry = ContentTypeRegistry()  // built-ins
        let originalOrder = registry.ids
        let position = try #require(originalOrder.firstIndex(of: "article"))
        let overridden = ContentTypeDescriptor(
            id: "article",
            displayName: "Long-form Article",
            storage: .collection("articles"),
            fields: [ContentTypeField("title", .string, required: true)],
            projections: ContentTypeProjections(
                microformat: "h-entry",
                microformatProperties: ["title": "p-name"],
                schemaType: "Article"
            )
        )
        registry.register(overridden)
        #expect(registry.ids == originalOrder)                       // order unchanged
        #expect(registry.ids.firstIndex(of: "article") == position)  // same slot
        #expect(registry.descriptor(id: "article")?.displayName == "Long-form Article")
    }

    @Test("init de-dupes by id, last-wins, first-seen order")
    func initDeDupes() {
        let a1 = ContentTypeDescriptor(
            id: "x", displayName: "First", storage: .page, fields: [],
            projections: ContentTypeProjections(microformat: "h-entry", microformatProperties: [:], schemaType: nil))
        let a2 = ContentTypeDescriptor(
            id: "x", displayName: "Second", storage: .page, fields: [],
            projections: ContentTypeProjections(microformat: "h-entry", microformatProperties: [:], schemaType: nil))
        let registry = ContentTypeRegistry(types: [a1, a2])
        #expect(registry.ids == ["x"])
        #expect(registry.descriptor(id: "x")?.displayName == "Second")
    }

    // MARK: Per-type declarations (≥3 types, distinct microformats + schema.org)

    @Test("Article projects h-entry + schema.org Article, with required body and date")
    func articleType() throws {
        let article = try #require(ContentTypeRegistry().descriptor(id: "article"))
        #expect(article.storage == .collection("articles"))
        #expect(article.collection == "articles")
        #expect(article.projections.microformat == "h-entry")
        #expect(article.projections.schemaType == "Article")
        #expect(article.projections.microformatProperties["title"] == "p-name")
        #expect(article.projections.microformatProperties["body"] == "e-content")
        #expect(article.projections.microformatProperties["publishDate"] == "dt-published")
        let required = Set(article.fields.filter(\.required).map(\.name))
        #expect(required == ["title", "body", "publishDate"])
    }

    @Test("Event projects h-event + schema.org Event with dt-start/dt-end")
    func eventType() throws {
        let event = try #require(ContentTypeRegistry().descriptor(id: "event"))
        #expect(event.projections.microformat == "h-event")
        #expect(event.projections.schemaType == "Event")
        #expect(event.projections.microformatProperties["start"] == "dt-start")
        #expect(event.projections.microformatProperties["end"] == "dt-end")
        // h-event dt-start/dt-end are datetimes (ISO 8601 with time + timezone), not bare dates.
        #expect(event.fields.first { $0.name == "start" }?.kind == .datetime)
        #expect(event.fields.first { $0.name == "end" }?.kind == .datetime)
    }

    @Test("Review projects h-review + schema.org Review with a numeric rating")
    func reviewType() throws {
        let review = try #require(ContentTypeRegistry().descriptor(id: "review"))
        #expect(review.projections.microformat == "h-review")
        #expect(review.projections.schemaType == "Review")
        #expect(review.projections.microformatProperties["rating"] == "p-rating")
        #expect(review.fields.first { $0.name == "rating" }?.kind == .number)
        #expect(review.fields.first { $0.name == "rating" }?.required == true)
    }

    @Test("Business Profile is a page projecting h-card + LocalBusiness")
    func businessProfileType() throws {
        let profile = try #require(ContentTypeRegistry().descriptor(id: "businessProfile"))
        #expect(profile.storage == .page)
        #expect(profile.collection == nil)
        #expect(profile.projections.microformat == "h-card")
        #expect(profile.projections.schemaType == "LocalBusiness")
        #expect(profile.projections.microformatProperties["telephone"] == "p-tel")
    }

    // MARK: Catalog invariants

    @Test("every built-in has a unique id, a microformat, and reachable mf2 fields")
    func builtInInvariants() {
        let registry = ContentTypeRegistry()
        let ids = registry.ids
        #expect(Set(ids).count == ids.count)  // ids unique

        for descriptor in registry.all {
            #expect(!descriptor.displayName.isEmpty)
            #expect(descriptor.projections.microformat.hasPrefix("h-"))
            // Every field referenced by an mf2 mapping must exist on the type.
            let fieldNames = Set(descriptor.fields.map(\.name))
            for mappedField in descriptor.projections.microformatProperties.keys {
                #expect(fieldNames.contains(mappedField),
                        "\(descriptor.id): mf2 maps unknown field '\(mappedField)'")
            }
            // A collection type must carry a non-empty collection name.
            if case let .collection(name) = descriptor.storage {
                #expect(!name.isEmpty)
                #expect(descriptor.collection == name)
            }
        }
    }
}
