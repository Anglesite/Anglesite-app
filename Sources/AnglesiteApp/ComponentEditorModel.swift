import Foundation
import AnglesiteCore
import Observation

/// Everything MainPaneEditorView needs to host a component editor; built by
/// the site window from PreviewModel state.
struct ComponentEditorContext {
    let baseURL: URL?
    let modelClient: ComponentModelClient?
    let sourceRoot: URL
}

@MainActor
@Observable
final class ComponentEditorModel {
    let file: FileRef
    let context: ComponentEditorContext

    /// Distinguishes "dev server/MCP client isn't up yet" (retryable, not a
    /// real failure — `ComponentEditorView`'s `loadKey` re-triggers `load()`
    /// once `context.baseURL`/the client become available) from a genuine
    /// load failure worth showing as an error page.
    enum LoadErrorReason: Equatable {
        case notConnected
        case other
    }

    private(set) var model: ComponentModel?
    private(set) var loadError: String?
    private(set) var loadErrorReason: LoadErrorReason?
    private(set) var isLoading = false
    var selectedNodeID: String?
    var computedStyles: [String: String] = [:]
    var knobValues: [String: String] = [:]

    init(file: FileRef, context: ComponentEditorContext) {
        self.file = file
        self.context = context
    }

    /// Path of this component relative to the site's Source/ root.
    var relativePath: String {
        let root = context.sourceRoot.path(percentEncoded: false)
        let full = file.url.path(percentEncoded: false)
        guard full.hasPrefix(root) else { return file.name }
        return String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var outlineRows: [ComponentOutline.Row] {
        guard let model else { return [] }
        return ComponentOutline.rows(from: model.template)
    }

    var harnessURL: URL? {
        guard let base = context.baseURL else { return nil }
        return HarnessURL.build(base: base, componentPath: relativePath, props: knobValues)
    }

    var selectedNode: ComponentModel.Node? {
        guard let id = selectedNodeID else { return nil }
        return outlineRows.first(where: { $0.node.id == id })?.node
    }

    func load() async {
        guard let client = context.modelClient else {
            loadError = "Site is not running yet."
            loadErrorReason = .notConnected
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await client.fetch(path: relativePath)
            model = fetched
            loadError = nil
            loadErrorReason = nil
            knobValues = Dictionary(
                uniqueKeysWithValues: (fetched.frontmatter?.props ?? []).map {
                    ($0.name, KnobDefaults.value(for: $0))
                }
            )
        } catch ComponentModelClient.ModelError.notConnected {
            loadError = "Site is not running yet."
            loadErrorReason = .notConnected
        } catch {
            loadError = String(describing: error)
            loadErrorReason = .other
        }
    }

    /// True when a canvas selection's `message.file` refers to the component
    /// currently being edited. The annotation file is vite-rooted (e.g.
    /// "/src/components/Card.astro" or an absolute filesystem path ending in
    /// that), while `relativePath` is project-relative (e.g.
    /// "src/components/Card.astro") — so compare via suffix, not equality.
    /// A selection elsewhere in the harness page (chrome, a nested child
    /// component's own markup) must not be line-matched against this
    /// component's outline.
    private func fileMatches(_ file: String?) -> Bool {
        guard let file, !file.isEmpty else { return false }
        let normalized = file.hasPrefix("/") ? String(file.dropFirst()) : file
        return normalized == relativePath || normalized.hasSuffix("/" + relativePath)
    }

    func canvasSelected(_ message: CanvasSelectionMessage) {
        guard let model,
              fileMatches(message.file),
              let line = message.line,
              let column = message.column
        else {
            selectedNodeID = nil
            return
        }
        selectedNodeID = ComponentOutline.node(atLine: line, column: column, in: model.template)?.id
    }
}
