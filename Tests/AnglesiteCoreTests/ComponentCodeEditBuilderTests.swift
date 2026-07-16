import Testing
@testable import AnglesiteCore

struct ComponentCodeEditBuilderTests {
    @Test("setPropsInterface builds a component payload with the full props array")
    func setPropsInterface() {
        let message = ComponentCodeEditBuilder.setPropsInterface(
            id: "1",
            path: "src/components/Card.astro",
            baseVersion: "sha256:abc123456789",
            props: [
                ComponentModel.Prop(name: "title", type: "string", optional: false, defaultValue: nil),
                ComponentModel.Prop(name: "count", type: "number", optional: true, defaultValue: "1"),
            ]
        )
        #expect(message.op == EditMessage.Op.setPropsInterface)
        #expect(message.selector == nil)
        #expect(message.path == "src/components/Card.astro")
        guard case .object(let component)? = message.component else {
            Issue.record("expected component object")
            return
        }
        #expect(component["path"] == .string("src/components/Card.astro"))
        #expect(component["baseVersion"] == .string("sha256:abc123456789"))
        #expect(component["props"] == .array([
            .object(["name": .string("title"), "type": .string("string"), "optional": .bool(false), "default": .null]),
            .object(["name": .string("count"), "type": .string("number"), "optional": .bool(true), "default": .string("1")]),
        ]))
    }

    @Test("setPropsInterface encodes an empty props array as [] (removal)")
    func setPropsInterfaceEmpty() {
        let message = ComponentCodeEditBuilder.setPropsInterface(
            id: "2",
            path: "src/components/Card.astro",
            baseVersion: "sha256:abc123456789",
            props: []
        )
        guard case .object(let component)? = message.component else {
            Issue.record("expected component object")
            return
        }
        #expect(component["props"] == .array([]))
    }

    @Test("setScriptZone builds a component payload with zone and source")
    func setScriptZoneFrontmatter() {
        let message = ComponentCodeEditBuilder.setScriptZone(
            id: "3",
            path: "src/components/Card.astro",
            baseVersion: "sha256:abc123456789",
            zone: "frontmatter",
            source: "const greeting = \"hi\";"
        )
        #expect(message.op == EditMessage.Op.setScriptZone)
        guard case .object(let component)? = message.component else {
            Issue.record("expected component object")
            return
        }
        #expect(component["zone"] == .string("frontmatter"))
        #expect(component["source"] == .string("const greeting = \"hi\";"))
    }

    @Test("setScriptZone works for the client zone too")
    func setScriptZoneClient() {
        let message = ComponentCodeEditBuilder.setScriptZone(
            id: "4",
            path: "src/components/Card.astro",
            baseVersion: "sha256:abc123456789",
            zone: "client",
            source: "console.log('mounted');"
        )
        guard case .object(let component)? = message.component else {
            Issue.record("expected component object")
            return
        }
        #expect(component["zone"] == .string("client"))
    }
}
