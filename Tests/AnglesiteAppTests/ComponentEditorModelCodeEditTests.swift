import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

@Suite("ComponentEditorModel props/code writes")
@MainActor
struct ComponentEditorModelCodeEditTests {
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

    @Test("setPropsInterface sends the built EditMessage and applies success")
    func setPropsInterfaceApplies() async {
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let model = makeModel(router: router)
        let props = [ComponentModel.Prop(name: "title", type: "string", optional: false, defaultValue: nil)]
        let applied = await model.setPropsInterface(props: props)
        #expect(applied)
        #expect(router.lastMessage?.op == EditMessage.Op.setPropsInterface)
        guard case .object(let component)? = router.lastMessage?.component else {
            Issue.record("expected component object")
            return
        }
        #expect(component["props"] == .array([
            .object(["name": .string("title"), "type": .string("string"), "optional": .bool(false), "default": .null]),
        ]))
    }

    @Test("setScriptZone sends the built EditMessage and applies success")
    func setScriptZoneApplies() async {
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let model = makeModel(router: router)
        let applied = await model.setScriptZone(zone: "client", source: "console.log('hi');")
        #expect(applied)
        #expect(router.lastMessage?.op == EditMessage.Op.setScriptZone)
        guard case .object(let component)? = router.lastMessage?.component else {
            Issue.record("expected component object")
            return
        }
        #expect(component["zone"] == .string("client"))
        #expect(component["source"] == .string("console.log('hi');"))
    }

    @Test("a stale reply flips conflict, same as the style/structure-write path")
    func staleFlipsConflict() async {
        let router = RecordingRouter(reply: EditReply(id: "x", status: .failed, message: "stale", reason: "stale"))
        let model = makeModel(router: router)
        let applied = await model.setPropsInterface(props: [])
        #expect(!applied)
        #expect(model.conflict)
    }

    @Test("a routine failure surfaces via writeError, not conflict")
    func routineFailureSurfacesWriteError() async {
        let router = RecordingRouter(reply: EditReply(id: "x", status: .failed, message: "invalid prop", reason: "invalid-input"))
        let model = makeModel(router: router)
        let applied = await model.setScriptZone(zone: "frontmatter", source: "const x = 1;")
        #expect(!applied)
        #expect(!model.conflict)
        #expect(model.writeError == "invalid prop")
    }
}
