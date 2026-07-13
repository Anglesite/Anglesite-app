import Foundation
import AnglesiteCore
import Observation

/// Everything MainPaneEditorView needs to host a component editor; built by
/// the site window from PreviewModel state.
struct ComponentEditorContext {
    let baseURL: URL?
    let modelClient: ComponentModelClient?
    let sourceRoot: URL
    /// Routes canvas-originated edits (e.g. a style tweak from the Styles
    /// panel) to the running site's MCP server. At the production call site
    /// (`SiteWindow`) this is always `model.preview.editRouter` — the same
    /// registered, chat-history-wired router the preview canvas uses — so
    /// edits made through either canvas behave identically. `nil` only for
    /// tests/previews that construct a context without write capability;
    /// `ComponentCanvasView` falls back to `LoggingEditRouter()` in that case.
    let editRouter: EditRouter?
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
    /// Set when a write op is refused as stale (the source changed outside Anglesite since
    /// `model` was fetched) — drives the "changed outside Anglesite — Reload" banner (design
    /// doc §5). `load()` is triggered automatically to refetch; the flag stays set until the
    /// caller acknowledges it (e.g. the panel dismisses it once the refreshed model renders).
    var conflict = false
    /// Set when a style write op fails for a reason other than staleness (invalid CSS value, a
    /// `no-match` on a drifted `ruleSpan`, a transient MCP/transport error). This is intentionally
    /// distinct from `loadError`/`loadErrorReason`: those drive `ComponentEditorView`'s full-pane
    /// `ContentUnavailableView` takeover, which would destroy the three-pane editor (outline/canvas/
    /// inspector) over a routine, retryable write failure and leave the user with no way to retry.
    /// `writeError` instead drives a small dismissible banner scoped to the Styles panel; `model`
    /// and `loadError` are left untouched so the editor pane stays live.
    var writeError: String?

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

    // MARK: - Style writes

    /// Set (or add) a CSS declaration's value within a `<style>` rule identified by `ruleSpan`.
    /// Returns whether the write actually applied — see `applyComponentStyleEdit`.
    @discardableResult
    func setStyleProperty(ruleSpan: [Int?], property: String, value: String) async -> Bool {
        await applyComponentStyleEdit(
            ComponentStyleEditBuilder.setStyleProperty(
                id: UUID().uuidString,
                path: relativePath,
                baseVersion: model?.version ?? "",
                ruleSpan: ruleSpan,
                property: property,
                value: value
            )
        )
    }

    /// Remove a CSS declaration from a rule identified by `ruleSpan`.
    /// Returns whether the write actually applied — see `applyComponentStyleEdit`.
    @discardableResult
    func removeStyleProperty(ruleSpan: [Int?], property: String) async -> Bool {
        await applyComponentStyleEdit(
            ComponentStyleEditBuilder.removeStyleProperty(
                id: UUID().uuidString,
                path: relativePath,
                baseVersion: model?.version ?? "",
                ruleSpan: ruleSpan,
                property: property
            )
        )
    }

    /// Rewrite a rule's selector.
    /// Returns whether the write actually applied — see `applyComponentStyleEdit`.
    @discardableResult
    func setRuleSelector(ruleSpan: [Int?], newSelector: String) async -> Bool {
        await applyComponentStyleEdit(
            ComponentStyleEditBuilder.setRuleSelector(
                id: UUID().uuidString,
                path: relativePath,
                baseVersion: model?.version ?? "",
                ruleSpan: ruleSpan,
                newSelector: newSelector
            )
        )
    }

    /// Add a new CSS rule to the component's `<style>` block.
    /// Returns whether the write actually applied — see `applyComponentStyleEdit`.
    @discardableResult
    func addStyleRule(selector: String, media: String?, declarations: [(property: String, value: String)]) async -> Bool {
        await applyComponentStyleEdit(
            ComponentStyleEditBuilder.addStyleRule(
                id: UUID().uuidString,
                path: relativePath,
                baseVersion: model?.version ?? "",
                selector: selector,
                media: media,
                declarations: declarations
            )
        )
    }

    /// The span of a style rule at `index` in the current `model`, or `nil` if the model isn't
    /// loaded or `index` is out of range. Used to re-derive a rule's span after a prior write in
    /// the same gesture may have shifted byte offsets within the file (see `ComponentEditorView
    /// .commitDeclaration`'s rename path, which removes then re-adds a declaration on the same
    /// rule — the remove shifts the rule's own end offset, so the follow-up add must target the
    /// freshly reloaded span, not the one captured before either write).
    func ruleSpan(atIndex index: Int) -> ComponentModel.Span? {
        guard let styles = model?.styles, styles.indices.contains(index) else { return nil }
        return styles[index].span
    }

    // MARK: - Structure writes

    /// Insert a new node as the child at `index` under `parentId` (the fragment root's id for
    /// a top-level insert). Returns whether the write actually applied.
    @discardableResult
    func insertNode(parentId: String, index: Int, node: ComponentStructureEditBuilder.NodeSpec) async -> Bool {
        await applyComponentStyleEdit(
            ComponentStructureEditBuilder.insertNode(
                id: UUID().uuidString,
                path: relativePath,
                baseVersion: model?.version ?? "",
                parentId: parentId,
                index: index,
                node: node
            )
        )
    }

    /// Reorder/reparent an existing node. Returns whether the write actually applied.
    @discardableResult
    func moveNode(nodeId: String, newParentId: String, newIndex: Int) async -> Bool {
        await applyComponentStyleEdit(
            ComponentStructureEditBuilder.moveNode(
                id: UUID().uuidString,
                path: relativePath,
                baseVersion: model?.version ?? "",
                nodeId: nodeId,
                newParentId: newParentId,
                newIndex: newIndex
            )
        )
    }

    /// Delete a node (the plugin prunes any now-unused component imports). Returns whether the
    /// write actually applied.
    @discardableResult
    func removeNode(nodeId: String) async -> Bool {
        await applyComponentStyleEdit(
            ComponentStructureEditBuilder.removeNode(
                id: UUID().uuidString,
                path: relativePath,
                baseVersion: model?.version ?? "",
                nodeId: nodeId
            )
        )
    }

    /// Set (`value` non-nil) or remove (`value == nil`) an attribute/prop at the use-site.
    /// Returns whether the write actually applied.
    @discardableResult
    func setAttr(nodeId: String, name: String, value: String?) async -> Bool {
        await applyComponentStyleEdit(
            ComponentStructureEditBuilder.setAttr(
                id: UUID().uuidString,
                path: relativePath,
                baseVersion: model?.version ?? "",
                nodeId: nodeId,
                name: name,
                value: value
            )
        )
    }

    /// Routes a built `EditMessage` to `context.editRouter` and reconciles the result. Shared by
    /// both the style writes above and the structure writes above (`insertNode`/`moveNode`/
    /// `removeNode`/`setAttr`) — the name is a slice-2 holdover, but the reconciliation logic is
    /// op-agnostic:
    /// - `.applied` with a piggybacked `reply.model` adopts it directly (no second fetch).
    /// - `.applied` without one falls back to `load()`.
    /// - `.failed` with reason `"stale"` (the plugin's machine-readable refusal code — see
    ///   `EditReply.reason`) triggers a `load()` refetch and flips `conflict` so the UI can
    ///   surface a "changed outside Anglesite — Reload" banner.
    /// - Any other `.failed` (or `.ambiguous`/`.preview`, which these ops never return) is a
    ///   routine, recoverable write failure — surfaced via `writeError`, NOT `loadError`/
    ///   `loadErrorReason` (see `writeError`'s doc comment for why).
    ///
    /// Returns whether the op actually applied — callers that must sequence a follow-up op
    /// against a rule this call may have mutated (e.g. a property rename's remove-then-add)
    /// use this to avoid compounding a failure and to know a fresh `model` is available.
    @discardableResult
    private func applyComponentStyleEdit(_ message: EditMessage) async -> Bool {
        guard let editRouter = context.editRouter else { return false }
        let reply = await editRouter.apply(message)
        switch reply.status {
        case .applied:
            conflict = false
            writeError = nil
            if let freshModel = reply.model {
                model = freshModel
            } else {
                await load()
            }
            return true
        case .failed where reply.reason == "stale":
            conflict = true
            await load()
            return false
        default:
            writeError = reply.message ?? "The edit couldn't be applied."
            return false
        }
    }
}
