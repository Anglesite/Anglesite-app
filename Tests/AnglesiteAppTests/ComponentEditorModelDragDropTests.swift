import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

/// Coverage for the outline/canvas drag-and-drop hit-testing and dispatch logic #824 moved out
/// of `ComponentEditorView` (`performMove`/`performInsert`/`performCanvasDrop`) and onto
/// `ComponentEditorModel`. The canvas's own JS bridging (evaluating the drop-target script
/// against a live `WKWebView`) isn't exercised here — only everything downstream of that decode,
/// which is what actually decides which `insertNode`/`moveNode` op fires.
@Suite("ComponentEditorModel drag & drop (#824)")
@MainActor
struct ComponentEditorModelDragDropTests {
    final class RecordingRouter: EditRouter {
        var lastMessage: EditMessage?
        var reply: EditReply
        init(reply: EditReply = EditReply(id: "x", status: .applied, message: nil)) { self.reply = reply }
        func apply(_ message: EditMessage) async -> EditReply {
            lastMessage = message
            return reply
        }
    }

    private func makeLoadedModel(router: EditRouter) async -> ComponentEditorModel {
        let json = ComponentEditorModelDraftStateTests.fixtureJSON
        let client = ComponentModelClient(toolCaller: { _, _ in
            MCPClient.ToolCallResult(content: [.init(type: "text", text: json)], isError: false)
        })
        let context = ComponentEditorContext(
            baseURL: nil, modelClient: client,
            sourceRoot: URL(fileURLWithPath: "/tmp/anglesite-dragdrop-tests-\(UUID().uuidString)"),
            editRouter: router
        )
        let file = FileRef(url: URL(fileURLWithPath: "/tmp/site/src/components/Card.astro"), group: .components, name: "Card.astro")
        let model = ComponentEditorModel(file: file, context: context)
        await model.load()
        return model
    }

    private func row(_ model: ComponentEditorModel, id: String) -> ComponentOutline.Row {
        model.outlineRows.first { $0.node.id == id }!
    }

    // MARK: - dropZone

    @Test("dropZone classifies a drop location into before/into/after by row-relative y")
    func dropZoneClassification() async {
        let model = await makeLoadedModel(router: RecordingRouter())
        let n2 = row(model, id: "n2")
        #expect(model.dropZone(at: CGPoint(x: 0, y: 2), for: n2) == .before)
        #expect(model.dropZone(at: CGPoint(x: 0, y: 11), for: n2) == .into)
        #expect(model.dropZone(at: CGPoint(x: 0, y: 20), for: n2) == .after)
    }

    @Test("dropZone redirects a sealed row's middle third to after, not into")
    func dropZoneSealedRedirect() async {
        let model = await makeLoadedModel(router: RecordingRouter())
        let sealedRow = row(model, id: "n5") // Badge component instance
        #expect(sealedRow.isSealed)
        #expect(model.dropZone(at: CGPoint(x: 0, y: 11), for: sealedRow) == .after)
    }

    // MARK: - performMove (outline drag-reorder)

    @Test("performMove into a target reparents as its last child")
    func performMoveInto() async {
        let router = RecordingRouter()
        let model = await makeLoadedModel(router: router)
        // Drag n4 (aside, sibling of section) into n1 (section) — becomes n1's last child.
        await model.performMove(draggedNodeID: "n4", targetRow: row(model, id: "n1"), location: CGPoint(x: 0, y: 11))
        #expect(router.lastMessage?.op == EditMessage.Op.moveNode)
        guard case .object(let obj)? = router.lastMessage?.component else {
            Issue.record("expected object payload")
            return
        }
        #expect(obj["nodeId"] == .string("n4"))
        #expect(obj["newParentId"] == .string("n1"))
        #expect(obj["newIndex"] == .int(2)) // after n1's existing 2 children (n2, n3)
    }

    @Test("performMove before a target reorders as its preceding sibling")
    func performMoveBefore() async {
        let router = RecordingRouter()
        let model = await makeLoadedModel(router: router)
        // Drag n3 (span) to before n2 (p) — both children of n1.
        await model.performMove(draggedNodeID: "n3", targetRow: row(model, id: "n2"), location: CGPoint(x: 0, y: 2))
        guard case .object(let obj)? = router.lastMessage?.component else {
            Issue.record("expected object payload")
            return
        }
        #expect(obj["nodeId"] == .string("n3"))
        #expect(obj["newParentId"] == .string("n1"))
        // n3 is already a later sibling of n2, so no post-removal shift applies: target index 0.
        #expect(obj["newIndex"] == .int(0))
    }

    @Test("performMove after a target reorders as its following sibling")
    func performMoveAfter() async {
        let router = RecordingRouter()
        let model = await makeLoadedModel(router: router)
        // Drag n2 (p) to after n3 (span) — both children of n1.
        await model.performMove(draggedNodeID: "n2", targetRow: row(model, id: "n3"), location: CGPoint(x: 0, y: 20))
        guard case .object(let obj)? = router.lastMessage?.component else {
            Issue.record("expected object payload")
            return
        }
        #expect(obj["nodeId"] == .string("n2"))
        #expect(obj["newParentId"] == .string("n1"))
        // n3's raw index is 1; n2 (index 0) is an earlier sibling being removed, so the
        // post-removal index shifts down by one: adjustedMoveIndex(2, 0) == 1.
        #expect(obj["newIndex"] == .int(1))
    }

    @Test("performMove refuses a reparent that would create a structural cycle")
    func performMoveRefusesCycle() async {
        let router = RecordingRouter()
        let model = await makeLoadedModel(router: router)
        // Dragging n1 (section) "into" n2 (its own child) must no-op — n2 is a descendant of n1.
        await model.performMove(draggedNodeID: "n1", targetRow: row(model, id: "n2"), location: CGPoint(x: 0, y: 11))
        #expect(router.lastMessage == nil)
    }

    // MARK: - performInsert (palette drop onto the outline)

    @Test("performInsert into a target inserts as its last child")
    func performInsertInto() async {
        let router = RecordingRouter()
        let model = await makeLoadedModel(router: router)
        await model.performInsert(payload: .element(tag: "img"), targetRow: row(model, id: "n1"), location: CGPoint(x: 0, y: 11))
        #expect(router.lastMessage?.op == EditMessage.Op.insertNode)
        guard case .object(let obj)? = router.lastMessage?.component else {
            Issue.record("expected object payload")
            return
        }
        #expect(obj["parentId"] == .string("n1"))
        #expect(obj["index"] == .int(2))
    }

    @Test("performInsert before a target inserts as its preceding sibling")
    func performInsertBefore() async {
        let router = RecordingRouter()
        let model = await makeLoadedModel(router: router)
        await model.performInsert(payload: .element(tag: "img"), targetRow: row(model, id: "n3"), location: CGPoint(x: 0, y: 2))
        guard case .object(let obj)? = router.lastMessage?.component else {
            Issue.record("expected object payload")
            return
        }
        #expect(obj["parentId"] == .string("n1"))
        #expect(obj["index"] == .int(1)) // n3's own index under n1
    }

    // MARK: - performCanvasDrop (drop directly on the rendered canvas)

    @Test("performCanvasDrop resolves the node at the reported source location and inserts relative to it")
    func performCanvasDropResolvesNode() async {
        let router = RecordingRouter()
        let model = await makeLoadedModel(router: router)
        // n2 ("p") is at line 5, column 10 in the fixture.
        await model.performCanvasDrop(atLine: 5, column: 10, zone: "after", payload: .element(tag: "img"))
        #expect(router.lastMessage?.op == EditMessage.Op.insertNode)
        guard case .object(let obj)? = router.lastMessage?.component else {
            Issue.record("expected object payload")
            return
        }
        #expect(obj["parentId"] == .string("n1"))
        #expect(obj["index"] == .int(1)) // right after n2 (index 0) under n1
    }

    @Test("performCanvasDrop redirects an into-drop on a sealed component instance to after")
    func performCanvasDropSealedRedirect() async {
        let router = RecordingRouter()
        let model = await makeLoadedModel(router: router)
        // n5 (Badge, kind == .component) is at line 10, column 1.
        await model.performCanvasDrop(atLine: 10, column: 1, zone: "into", payload: .element(tag: "img"))
        #expect(router.lastMessage?.op == EditMessage.Op.insertNode)
        guard case .object(let obj)? = router.lastMessage?.component else {
            Issue.record("expected object payload")
            return
        }
        // Redirected to "after" n5 under the fragment root, not "into" the sealed instance.
        #expect(obj["parentId"] == .string("n0"))
        #expect(obj["index"] == .int(3)) // n5 is the root's 3rd child (index 2), so after == 3
    }

    @Test("performCanvasDrop is a no-op when the reported location doesn't resolve to any node")
    func performCanvasDropNoMatch() async {
        let router = RecordingRouter()
        let model = await makeLoadedModel(router: router)
        await model.performCanvasDrop(atLine: 999, column: 1, zone: "after", payload: .element(tag: "img"))
        #expect(router.lastMessage == nil)
    }
}
