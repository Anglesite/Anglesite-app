import Testing
import Foundation
@testable import AnglesiteCore

// Gated like the type under test — `AltTextGenerator` references `GeneratedAltText` (`@Generable`,
// Xcode-27 only). The logic here is model-free: the vision call is injected as a closure.
#if compiler(>=6.4) && canImport(FoundationModels)

@Suite("AltTextGenerator")
struct AltTextGeneratorTests {

    /// Collects the follow-up edits the generator applies, so tests can assert on them.
    private actor Recorder {
        private(set) var edits: [EditMessage] = []
        func record(_ edit: EditMessage) { edits.append(edit) }
    }

    private let siteDir = URL(fileURLWithPath: "/tmp/my-site", isDirectory: true)

    /// An image-drop reply as `MCPApplyEditRouter` would produce it.
    private func imageDropReply(src: String? = "/images/hero.webp") -> EditReply {
        EditReply(
            id: "drop-1", status: .applied, message: nil, file: "src/pages/index.md",
            commit: "abc123", result: src.map { EditReply.ImageResult(src: $0, srcset: nil) }
        )
    }

    /// The original drop message — its `path`/`selector` must be reused for the follow-up.
    private func imageDropMessage() -> EditMessage {
        EditMessage(
            id: "drop-1", type: .applyEdit, path: "/about/",
            selector: .object(["tag": .string("img"), "index": .int(0)]),
            op: EditMessage.Op.replaceImageSrc, value: nil
        )
    }

    private func makeGenerator(
        enabled: Bool = true,
        recorder: Recorder,
        produce: @escaping AltTextGenerator.Producer
    ) -> AltTextGenerator {
        AltTextGenerator(
            siteID: "site-1",
            siteDirectory: siteDir,
            isEnabled: { enabled },
            produce: produce,
            apply: { await recorder.record($0) },
            log: { _ in }
        )
    }

    @Test("applies a single replace-attr alt edit for a non-decorative image")
    func appliesAltEdit() async {
        let recorder = Recorder()
        let gen = makeGenerator(recorder: recorder) { _, _ in
            GeneratedAltText(altText: "A white circle on a blue square", isDecorative: false)
        }
        await gen.postProcess(reply: imageDropReply(), message: imageDropMessage())

        let edits = await recorder.edits
        #expect(edits.count == 1)
        let edit = try? #require(edits.first)
        #expect(edit?.op == EditMessage.Op.replaceAttr)
        #expect(edit?.path == "/about/")
        #expect(edit?.selector == .object(["tag": .string("img"), "index": .int(0)]))
        #expect(edit?.value == .object(["name": .string("alt"), "value": .string("A white circle on a blue square")]))
    }

    @Test("decorative image sets empty alt and role=presentation (two edits)")
    func decorativeAppliesAltAndRole() async {
        let recorder = Recorder()
        let gen = makeGenerator(recorder: recorder) { _, _ in
            GeneratedAltText(altText: "", isDecorative: true)
        }
        await gen.postProcess(reply: imageDropReply(), message: imageDropMessage())

        let edits = await recorder.edits
        #expect(edits.count == 2)
        #expect(edits.first?.value == .object(["name": .string("alt"), "value": .string("")]))
        #expect(edits.last?.value == .object(["name": .string("role"), "value": .string("presentation")]))
    }

    @Test("resolves the site-relative src to a file under public/")
    func resolvesImagePath() async {
        let recorder = Recorder()
        var seenURL: URL?
        let gen = makeGenerator(recorder: recorder) { url, _ in
            seenURL = url
            return GeneratedAltText(altText: "x", isDecorative: false)
        }
        await gen.postProcess(reply: imageDropReply(src: "/images/hero.webp"), message: imageDropMessage())
        #expect(seenURL?.path == "/tmp/my-site/public/images/hero.webp")
    }

    @Test("does nothing when disabled") func disabledNoOp() async {
        let recorder = Recorder()
        let gen = makeGenerator(enabled: false, recorder: recorder) { _, _ in
            GeneratedAltText(altText: "x", isDecorative: false)
        }
        await gen.postProcess(reply: imageDropReply(), message: imageDropMessage())
        #expect(await recorder.edits.isEmpty)
    }

    @Test("ignores non-image-drop edits") func ignoresNonImageOps() async {
        let recorder = Recorder()
        let gen = makeGenerator(recorder: recorder) { _, _ in
            GeneratedAltText(altText: "x", isDecorative: false)
        }
        let textEdit = EditMessage(
            id: "t-1", type: .applyEdit, path: "/about/",
            selector: .object(["tag": .string("h1")]), op: EditMessage.Op.replaceText, value: .string("Hi")
        )
        await gen.postProcess(reply: imageDropReply(), message: textEdit)
        #expect(await recorder.edits.isEmpty)
    }

    @Test("ignores failed replies") func ignoresFailedReplies() async {
        let recorder = Recorder()
        let gen = makeGenerator(recorder: recorder) { _, _ in
            GeneratedAltText(altText: "x", isDecorative: false)
        }
        let failed = EditReply(id: "drop-1", status: .failed, message: "nope")
        await gen.postProcess(reply: failed, message: imageDropMessage())
        #expect(await recorder.edits.isEmpty)
    }

    @Test("ignores replies without an image result") func ignoresMissingResult() async {
        let recorder = Recorder()
        let gen = makeGenerator(recorder: recorder) { _, _ in
            GeneratedAltText(altText: "x", isDecorative: false)
        }
        await gen.postProcess(reply: imageDropReply(src: nil), message: imageDropMessage())
        #expect(await recorder.edits.isEmpty)
    }

    @Test("a failed generation is swallowed, leaving the edit untouched") func generationFailureIsBestEffort() async {
        let recorder = Recorder()
        struct Boom: Error {}
        let gen = makeGenerator(recorder: recorder) { _, _ in throw Boom() }
        await gen.postProcess(reply: imageDropReply(), message: imageDropMessage())
        #expect(await recorder.edits.isEmpty)
    }
}
#endif
