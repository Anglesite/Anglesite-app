import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

@Suite("ComponentEditorModel structure writes")
@MainActor
struct ComponentEditorModelStructureEditTests {
    final class RecordingRouter: EditRouter {
        var lastMessage: EditMessage?
        var reply: EditReply
        init(reply: EditReply) { self.reply = reply }
        func apply(_ message: EditMessage) async -> EditReply {
            lastMessage = message
            return reply
        }
    }

    func makeModel(router: EditRouter) -> ComponentEditorModel {
        let context = ComponentEditorContext(baseURL: nil, modelClient: nil, sourceRoot: URL(fileURLWithPath: "/tmp/site"), editRouter: router)
        let file = FileRef(url: URL(fileURLWithPath: "/tmp/site/src/components/Card.astro"), group: .components, name: "Card.astro")
        return ComponentEditorModel(file: file, context: context)
    }

    @Test("insertNode sends the built EditMessage and applies success")
    func insertNodeApplies() async {
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let model = makeModel(router: router)
        let applied = await model.insertNode(parentId: "n0", index: 0, node: .element(tag: "p"))
        #expect(applied)
        #expect(router.lastMessage?.op == EditMessage.Op.insertNode)
    }

    @Test("moveNode sends the built EditMessage")
    func moveNodeApplies() async {
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let model = makeModel(router: router)
        let applied = await model.moveNode(nodeId: "n2", newParentId: "n0", newIndex: 1)
        #expect(applied)
        #expect(router.lastMessage?.op == EditMessage.Op.moveNode)
    }

    @Test("removeNode sends the built EditMessage")
    func removeNodeApplies() async {
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let model = makeModel(router: router)
        let applied = await model.removeNode(nodeId: "n2")
        #expect(applied)
        #expect(router.lastMessage?.op == EditMessage.Op.removeNode)
    }

    @Test("setAttr sends the built EditMessage")
    func setAttrApplies() async {
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let model = makeModel(router: router)
        let applied = await model.setAttr(nodeId: "n1", name: "class", value: "big")
        #expect(applied)
        #expect(router.lastMessage?.op == EditMessage.Op.setAttr)
    }

    @Test("a stale reply flips conflict, same as the style-write path")
    func staleFlipsConflict() async {
        let router = RecordingRouter(reply: EditReply(id: "x", status: .failed, message: "stale", reason: "stale"))
        let model = makeModel(router: router)
        let applied = await model.setAttr(nodeId: "n1", name: "class", value: "big")
        #expect(!applied)
        #expect(model.conflict)
    }

    @Test("extractComponent sends the built EditMessage carrying a bare newName and applies success")
    func extractComponentApplies() async {
        let router = RecordingRouter(reply: EditReply(
            id: "x",
            status: .applied,
            message: nil,
            newFile: "src/components/Hero.astro"
        ))
        let model = makeModel(router: router)
        let applied = await model.extractComponent(nodeId: "n3", newName: "Hero")
        #expect(applied)
        #expect(router.lastMessage?.op == EditMessage.Op.extractComponent)
        // The op carries the bare name straight through as `newName` — no client-side path building.
        guard case .object(let obj)? = router.lastMessage?.component else { Issue.record("expected object component payload"); return }
        #expect(obj["newName"] == .string("Hero"))
        #expect(obj["nodeId"] == .string("n3"))
    }

    @Test("extractComponent surfaces a plugin already-exists refusal via writeError")
    func extractComponentRefusalSurfacesWriteError() async {
        let router = RecordingRouter(reply: EditReply(id: "x", status: .failed, message: "That component already exists.", reason: "already-exists"))
        let model = makeModel(router: router)
        let applied = await model.extractComponent(nodeId: "n3", newName: "Hero")
        #expect(!applied)
        #expect(model.writeError == "That component already exists.")
        #expect(!model.conflict)
    }

    @Test("extractComponent surfaces a dynamic-expression refusal via writeError")
    func extractComponentDynamicExpressionSurfacesWriteError() async {
        // `dynamic-expression` is a routine, non-`stale` refusal, so it flows through the generic
        // failure branch into `writeError` exactly like `already-exists` — no special-casing.
        let router = RecordingRouter(reply: EditReply(id: "x", status: .failed, message: "Can't extract a subtree with dynamic content.", reason: "dynamic-expression"))
        let model = makeModel(router: router)
        let applied = await model.extractComponent(nodeId: "n3", newName: "Hero")
        #expect(!applied)
        #expect(model.writeError == "Can't extract a subtree with dynamic content.")
        #expect(!model.conflict)
    }

    @Test("extractComponent stale refusal flips conflict")
    func extractComponentStaleFlipsConflict() async {
        let router = RecordingRouter(reply: EditReply(id: "x", status: .failed, message: "stale", reason: "stale"))
        let model = makeModel(router: router)
        let applied = await model.extractComponent(nodeId: "n3", newName: "Hero")
        #expect(!applied)
        #expect(model.conflict)
    }
}
