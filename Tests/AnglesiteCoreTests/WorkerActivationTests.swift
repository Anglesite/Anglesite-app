import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WorkerActivation")
struct WorkerActivationTests {
    private func descriptor(
        id: String, group: String = "social", binding: WorkerDescriptor.Binding
    ) -> WorkerDescriptor {
        WorkerDescriptor(
            id: id, displayName: id, description: "d", group: group, binding: binding,
            resources: .init(needsD1: false, needsKV: false, needsR2: false)
        )
    }

    private func pageNode(id: String) -> SiteGraphNode {
        SiteGraphNode(id: id, kind: .page, title: id, detail: nil, filePath: nil, route: "/\(id)")
    }

    private func componentNode(id: String) -> SiteGraphNode {
        SiteGraphNode(id: id, kind: .component, title: id, detail: nil, filePath: nil, route: nil)
    }

    @Test("a component-tied worker is active when its component is used by a page")
    func componentTiedActiveWhenPageUsesIt() {
        let catalog = [descriptor(id: "webmention", binding: .componentTied(componentIDs: ["webmention-form"]))]
        let graph = SiteGraphExplorerSnapshot(
            nodes: [pageNode(id: "page:home"), componentNode(id: "webmention-form")],
            edges: [SiteGraphEdge(sourceID: "page:home", targetID: "webmention-form", kind: .imports)]
        )
        let active = WorkerActivation.effectiveActiveIDs(settings: SiteSettings(), catalog: catalog, graph: graph)
        #expect(active == ["webmention"])
    }

    @Test("a component-tied worker is inactive when its component is unused")
    func componentTiedInactiveWhenUnused() {
        let catalog = [descriptor(id: "webmention", binding: .componentTied(componentIDs: ["webmention-form"]))]
        let graph = SiteGraphExplorerSnapshot(
            nodes: [pageNode(id: "page:home"), componentNode(id: "webmention-form")],
            edges: []
        )
        let active = WorkerActivation.effectiveActiveIDs(settings: SiteSettings(), catalog: catalog, graph: graph)
        #expect(active.isEmpty)
    }

    @Test("a component-tied worker is inactive when the graph is nil (headless deploy)")
    func componentTiedInactiveWhenGraphIsNil() {
        let catalog = [descriptor(id: "webmention", binding: .componentTied(componentIDs: ["webmention-form"]))]
        let active = WorkerActivation.effectiveActiveIDs(settings: SiteSettings(), catalog: catalog, graph: nil)
        #expect(active.isEmpty)
    }

    @Test("a component used only by another (page-unreachable) component does not count")
    func componentTiedRequiresAffectedPageNotJustAnyDependent() {
        let catalog = [descriptor(id: "webmention", binding: .componentTied(componentIDs: ["webmention-form"]))]
        // "wrapper" imports "webmention-form", but nothing imports "wrapper" — no page is affected.
        let graph = SiteGraphExplorerSnapshot(
            nodes: [componentNode(id: "wrapper"), componentNode(id: "webmention-form")],
            edges: [SiteGraphEdge(sourceID: "wrapper", targetID: "webmention-form", kind: .imports)]
        )
        let active = WorkerActivation.effectiveActiveIDs(settings: SiteSettings(), catalog: catalog, graph: graph)
        #expect(active.isEmpty)
    }

    @Test("a settings-activated worker is active when its id is in activeWorkerIDs")
    func settingsActivatedFromSettings() {
        let catalog = [descriptor(id: "solid-pod", group: "storage", binding: .settingsActivated)]
        let settings = SiteSettings(activeWorkerIDs: ["solid-pod"])
        let active = WorkerActivation.effectiveActiveIDs(settings: settings, catalog: catalog, graph: nil)
        #expect(active == ["solid-pod"])
    }

    @Test("a stale activeWorkerIDs entry no longer in the catalog is dropped")
    func staleActiveIDDropped() {
        let catalog = [descriptor(id: "solid-pod", group: "storage", binding: .settingsActivated)]
        let settings = SiteSettings(activeWorkerIDs: ["solid-pod", "retired-worker"])
        let active = WorkerActivation.effectiveActiveIDs(settings: settings, catalog: catalog, graph: nil)
        #expect(active == ["solid-pod"])
    }

    @Test("an activeWorkerIDs entry for a componentTied catalog id does not activate it directly")
    func activeWorkerIDsIgnoredForComponentTiedEntries() {
        // Defensive: activeWorkerIDs should only ever contain settingsActivated ids in practice,
        // but a componentTied id ending up there (e.g. stale data) must not bypass usage detection.
        let catalog = [descriptor(id: "webmention", binding: .componentTied(componentIDs: ["webmention-form"]))]
        let settings = SiteSettings(activeWorkerIDs: ["webmention"])
        let active = WorkerActivation.effectiveActiveIDs(settings: settings, catalog: catalog, graph: nil)
        #expect(active.isEmpty)
    }

    @Test("an empty catalog trusts activeWorkerIDs verbatim rather than deactivating everything")
    func emptyCatalogTrustsActiveWorkerIDs() {
        let settings = SiteSettings(activeWorkerIDs: ["solid-pod", "webdav"])
        let active = WorkerActivation.effectiveActiveIDs(settings: settings, catalog: [], graph: nil)
        #expect(active == ["solid-pod", "webdav"])
    }

    @Test("removedIDs is the previous set minus the next set")
    func removedIDsIsSetDifference() {
        let removed = WorkerActivation.removedIDs(previous: ["webmention", "indieauth"], next: ["indieauth"])
        #expect(removed == ["webmention"])
        #expect(WorkerActivation.removedIDs(previous: ["a"], next: ["a", "b"]).isEmpty)
    }

    @Test("activeDescriptors resolves known ids against the catalog")
    func activeDescriptorsKnownIDs() {
        let webmention = descriptor(id: "webmention", binding: .settingsActivated)
        let indieauth = descriptor(id: "indieauth", binding: .settingsActivated)
        let resolved = WorkerActivation.activeDescriptors(
            catalog: [webmention, indieauth], activeIDs: ["indieauth", "webmention"])
        #expect(Set(resolved.map(\.id)) == ["indieauth", "webmention"])
    }

    @Test("activeDescriptors drops ids with no matching catalog entry")
    func activeDescriptorsDropsUnknownIDs() {
        let indieauth = descriptor(id: "indieauth", binding: .settingsActivated)
        let resolved = WorkerActivation.activeDescriptors(
            catalog: [indieauth], activeIDs: ["indieauth", "solid-pod"])
        #expect(resolved.map(\.id) == ["indieauth"])
    }

    @Test("activeDescriptors of an empty id set is empty")
    func activeDescriptorsEmpty() {
        let indieauth = descriptor(id: "indieauth", binding: .settingsActivated)
        #expect(WorkerActivation.activeDescriptors(catalog: [indieauth], activeIDs: []).isEmpty)
    }
}
