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
    /// Opens a different file in the main pane — used to implement "double-click a sealed
    /// component instance to edit its own definition" (spec §4.1). `nil` in
    /// tests/previews that don't need navigation.
    var onOpenFile: ((FileRef) -> Void)? = nil
}

@MainActor
@Observable
final class ComponentEditorModel {
    let file: FileRef
    let context: ComponentEditorContext

    /// Distinguishes "dev server/MCP client isn't up yet" (retryable, not a
    /// real failure — `ComponentEditorView`'s `loadKey` re-triggers `load()`
    /// once `context.baseURL`/the client become available) from an
    /// unparseable component (design spec §5: degrade to the Source tab with
    /// the compiler diagnostic in a banner, never a dead end) from any other
    /// genuine load failure worth showing as a full-pane error.
    enum LoadErrorReason: Equatable {
        case notConnected
        case unparseable
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
    /// Non-fatal advisories from the last `extract-component` op (e.g. a scoped style rule the
    /// plugin couldn't migrate) — drives the dismissible warnings banner. Set only when the
    /// extraction applied with a non-empty `warnings` list; `nil` otherwise, and cleared on the
    /// next successful `load()` or applied edit.
    var extractWarnings: [String]?
    /// Sibling project components for the palette — scanned once per `load()`, not per render.
    private(set) var projectComponents: [FileRef] = []

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
            extractWarnings = nil
            knobValues = Dictionary(
                uniqueKeysWithValues: (fetched.frontmatter?.props ?? []).map {
                    ($0.name, KnobDefaults.value(for: $0))
                }
            )
            projectComponents = SiteFileTree.scan(siteRoot: context.sourceRoot)[.components] ?? []
        } catch let error as ComponentModelClient.ModelError {
            loadError = error.friendlyMessage
            switch error {
            case .notConnected: loadErrorReason = .notConnected
            case .toolFailed(let reason, _): loadErrorReason = reason == "parse-failed" ? .unparseable : .other
            case .decodeFailed: loadErrorReason = .other
            }
        } catch {
            loadError = "Couldn't load this component: \(error.localizedDescription)"
            loadErrorReason = .other
        }
    }

    func canvasSelected(_ message: CanvasSelectionMessage) {
        guard let model,
              ComponentOutline.fileMatches(message.file, relativePath: relativePath),
              let line = message.line,
              let column = message.column
        else {
            selectedNodeID = nil
            return
        }
        selectedNodeID = ComponentOutline.node(atLine: line, column: column, in: model.template)?.id
    }

    /// Resolves `tag` (a component instance's tag name, e.g. "Badge") against `projectComponents`
    /// and asks the host to open it. No-op if the tag can't be resolved or navigation isn't wired.
    func openReferencedComponent(tag: String?) {
        guard let tag, let match = projectComponents.first(where: { $0.name == "\(tag).astro" }) else { return }
        context.onOpenFile?(match)
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

    // MARK: - Props & code writes

    /// Codegen/replace the `Props` interface + `Astro.props` destructure from a structured props
    /// array (the Props form). An empty array removes both. `applyComponentStyleEdit`'s
    /// piggybacked-model path adopts the fresh model but doesn't otherwise know to touch
    /// `knobValues` (it's op-agnostic), so this op resyncs the knobs bar itself on success:
    /// existing knob values survive for props that still exist (by name), renamed/removed props
    /// drop out, and newly added props get their type-based default. Returns whether the write
    /// applied.
    @discardableResult
    func setPropsInterface(props: [ComponentModel.Prop]) async -> Bool {
        let applied = await applyComponentStyleEdit(
            ComponentCodeEditBuilder.setPropsInterface(
                id: UUID().uuidString,
                path: relativePath,
                baseVersion: model?.version ?? "",
                props: props
            )
        )
        if applied { syncKnobValues() }
        return applied
    }

    /// Rebuilds `knobValues` against the current `model`'s props, keyed by name — see
    /// `setPropsInterface`'s doc comment for why this is needed after that op specifically.
    private func syncKnobValues() {
        let props = model?.frontmatter?.props ?? []
        var next: [String: String] = [:]
        for prop in props {
            next[prop.name] = knobValues[prop.name] ?? KnobDefaults.value(for: prop)
        }
        knobValues = next
    }

    /// Replace a whole script zone (`"frontmatter"` or `"client"`) wholesale — a code-pane save.
    /// Returns whether the write actually applied.
    @discardableResult
    func setScriptZone(zone: String, source: String) async -> Bool {
        await applyComponentStyleEdit(
            ComponentCodeEditBuilder.setScriptZone(
                id: UUID().uuidString,
                path: relativePath,
                baseVersion: model?.version ?? "",
                zone: zone,
                source: source
            )
        )
    }

    /// Routes a built `EditMessage` to `context.editRouter` and reconciles the result. Shared by
    /// the style writes, the structure writes (`insertNode`/`moveNode`/`removeNode`/`setAttr`),
    /// and the props/code writes above (`setPropsInterface`/`setScriptZone`) — the name is a
    /// slice-2 holdover, but the reconciliation logic is op-agnostic:
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
            // A successful unrelated edit clears any lingering extract warnings (a fresh model
            // adoption below doesn't run `load()`, which is the other place they'd clear).
            extractWarnings = nil
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

    // MARK: - Extract into component

    /// Extract the subtree rooted at `nodeId` into a brand-new `.astro` component at
    /// `newComponentPath`, replacing the extracted markup with a self-closing instance + import.
    /// The plugin applies this as one atomic two-file edit; the reconciliation here mirrors the
    /// other structure writes (`applyComponentStyleEdit`) — adopt a piggybacked fresh `model` for
    /// the original file or reload; a `stale` refusal flips `conflict` and reloads — and
    /// additionally surfaces the op's non-fatal `warnings` via `extractWarnings` for the banner.
    /// The `newComponentPath` client-side validation lives in `ExtractComponentSheet`; the
    /// plugin's own `invalid-input`/`exists` refusals still surface here via `writeError`.
    /// Returns whether the extraction applied.
    @discardableResult
    func extractComponent(nodeId: String, newComponentPath: String) async -> Bool {
        guard let editRouter = context.editRouter else { return false }
        let message = ComponentStructureEditBuilder.extractComponent(
            id: UUID().uuidString,
            path: relativePath,
            baseVersion: model?.version ?? "",
            nodeId: nodeId,
            newComponentPath: newComponentPath
        )
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
            // Set last: `load()` above clears `extractWarnings`, so surfacing the op's warnings
            // must happen after the model reconciliation, not before.
            let warnings = reply.extractResult?.warnings ?? []
            extractWarnings = warnings.isEmpty ? nil : warnings
            return true
        case .failed where reply.reason == "stale":
            conflict = true
            await load()
            return false
        default:
            writeError = reply.message ?? "The component couldn't be extracted."
            return false
        }
    }

    /// Whether the outline `row` can be extracted into its own component. Delegates to
    /// `ComponentOutline.isExtractable(_:)` (Core), which hosts the actual gating logic so it's
    /// unit-testable on CI (app-target Swift tests don't run there).
    func canExtractComponent(_ row: ComponentOutline.Row) -> Bool {
        ComponentOutline.isExtractable(row.node)
    }
}
