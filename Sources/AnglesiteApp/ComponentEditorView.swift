import SwiftUI
import WebKit
import AnglesiteCore
import AnglesiteBridge
import STTextView
import STPluginNeon
import TreeSitterResource

/// Component Editor: outline + harness canvas + inspector (with interactive Styles panel and structure edits).
struct ComponentEditorView: View {
    let file: FileRef
    let context: ComponentEditorContext
    @Bindable var fileEditor: FileEditorModel

    @State private var model: ComponentEditorModel?
    /// Design (three-pane) vs Source (existing text editor) — the escape hatch.
    @State private var mode: Mode = .design
    @State private var webView: WKWebView?
    /// Canvas viewport-width preset (design spec §3/§4.2) — "Fill" (the default) matches the
    /// pre-slice-5 behavior of the harness filling the available pane width.
    @State private var viewportPreset: ComponentViewportPreset = .fill

    /// In-progress edits to a rule's selector, keyed by `spanKey(rule.span)`,
    /// pending commit (on focus loss) to `ComponentEditorModel.setRuleSelector`.
    @State private var selectorDrafts: [String: String] = [:]
    /// In-progress edits to a declaration's property name, keyed by
    /// `spanKey(decl.span)`, pending commit to `setStyleProperty`.
    @State private var propertyDrafts: [String: String] = [:]
    /// In-progress edits to a declaration's value, keyed by `spanKey(decl.span)`.
    @State private var valueDrafts: [String: String] = [:]
    /// Pending debounced commit from a `ColorPicker` drag, keyed by `spanKey(decl.span)`.
    /// macOS `ColorPicker` updates its binding continuously while the system color panel is
    /// being dragged, so committing on every change would fire a burst of redundant
    /// `setStyleProperty` round-trips (and risk spurious `.failed`/stale-`baseVersion` conflicts).
    /// Each new picker value cancels the previous pending commit and restarts the delay, so only
    /// the settled value after the drag pauses actually commits.
    @State private var colorCommitTasks: [String: Task<Void, Never>] = [:]
    /// Selector text for the inline "Add rule" form at the bottom of the Styles panel.
    @State private var newRuleSelector: String = ""
    /// `@media` condition text for the inline "Add rule" form; blank means no wrapping media
    /// query (same as passing `nil` to `addStyleRule`).
    @State private var newRuleMedia: String = ""
    /// Media keys (via `mediaGroupKey`) the user has manually collapsed — a `DisclosureGroup`
    /// per media section defaults to expanded, matching the old flat list's always-visible rules.
    @State private var collapsedMediaKeys: Set<String> = []
    /// In-progress edits to an attribute value, keyed by `"<nodeID>:<attrName>"`, pending
    /// commit (on submit) to `ComponentEditorModel.setAttr`.
    @State private var attrValueDrafts: [String: String] = [:]
    /// Name/value text for the inline "Add attribute" form in the Selection panel.
    @State private var newAttrName: String = ""
    @State private var newAttrValue: String = ""
    /// Editable draft of the component's Props interface (Props form), seeded from
    /// `model.model?.frontmatter?.props` whenever a fresh model loads and reconciled back via
    /// an explicit "Save Props" action — the op replaces the whole interface atomically, so
    /// per-field auto-commit (like the Styles panel's declaration rows) doesn't fit here.
    @State private var propsDraft: [PropDraft] = []
    /// Which code pane is showing — "Props & Data" (frontmatter TS) or "Behavior" (client
    /// script). Design spec §4.3.
    @State private var codeZone: CodeZone = .frontmatter
    /// Editable drafts for the two code panes, keyed by zone — dirty-tracked like
    /// `FileEditorModel` (spec §5) and saved explicitly via `setScriptZone`, not on blur.
    @State private var codeDrafts: [CodeZone: String] = [.frontmatter: "", .client: ""]

    enum Mode: String, CaseIterable { case design = "Design", source = "Source" }

    /// The two code panes' zones (design spec §4.3): frontmatter TS ("Props & Data") and the
    /// client `<script>` ("Behavior"). Maps 1:1 to `EditMessage.Op.setScriptZone`'s wire values.
    private enum CodeZone: String, CaseIterable, Hashable {
        case frontmatter, client

        var label: String {
            switch self {
            case .frontmatter: "Props & Data"
            case .client: "Behavior"
            }
        }

        var language: TreeSitterLanguage {
            switch self {
            case .frontmatter: .typescript
            case .client: .javascript
            }
        }
    }

    /// One row in the Props form. `id` is a stable SwiftUI identity for `ForEach`/drafting —
    /// excluded from `==` (see the custom `Equatable` below) so draft-vs-model dirty checks
    /// compare content only, not incidental per-row identity.
    private struct PropDraft: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var type: String
        var optional: Bool
        var defaultValue: String

        init(name: String, type: String, optional: Bool, defaultValue: String) {
            self.name = name
            self.type = type
            self.optional = optional
            self.defaultValue = defaultValue
        }

        init(_ prop: ComponentModel.Prop) {
            self.init(name: prop.name, type: prop.type, optional: prop.optional, defaultValue: prop.defaultValue ?? "")
        }

        static func == (lhs: PropDraft, rhs: PropDraft) -> Bool {
            lhs.name == rhs.name && lhs.type == rhs.type && lhs.optional == rhs.optional && lhs.defaultValue == rhs.defaultValue
        }
    }

    init(file: FileRef, context: ComponentEditorContext, fileEditor: FileEditorModel) {
        self.file = file
        self.context = context
        self.fileEditor = fileEditor
    }

    /// Identity for the load task: re-runs (and rebuilds `model`) whenever
    /// the edited file changes OR the dev server transitions from not-ready
    /// to ready (or back), rather than freezing the context/model at the
    /// view's first identity. `baseURL` is included as a String so a
    /// nil→non-nil transition (dev server finishing startup) is itself a
    /// new task identity, not just a value the stale model captured once.
    private struct LoadKey: Hashable {
        let baseURL: String?
        let fileID: String
    }

    private var loadKey: LoadKey {
        LoadKey(baseURL: context.baseURL?.absoluteString, fileID: file.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch mode {
            case .design: designPane
            case .source: sourcePane
            }
        }
        .task(id: loadKey) {
            let freshModel = ComponentEditorModel(file: file, context: context)
            model = freshModel
            await freshModel.load()
        }
        .onChange(of: model?.selectedNodeID) { _, newValue in
            highlightInCanvas(nodeID: newValue)
        }
        .onChange(of: model?.loadErrorReason) { _, newValue in
            // Design spec §5: an unparseable component degrades to the Source tab with the
            // compiler diagnostic in a banner, rather than a dead-end full-pane error — fixing
            // the syntax error in source is the only way out, so land the user where they can.
            if newValue == .unparseable { mode = .source }
        }
        .onChange(of: model?.model?.version) { _, _ in
            // A fresh model version means a fresh Props form / code pane baseline — re-seed
            // both drafts. Any in-progress, unsaved edits are intentionally discarded here (the
            // same tradeoff a stale-write "Reload" already makes elsewhere in this editor).
            propsDraft = (model?.model?.frontmatter?.props ?? []).map(PropDraft.init)
            codeDrafts = [
                .frontmatter: model?.model?.frontmatter?.source ?? "",
                .client: model?.model?.clientScript?.source ?? "",
            ]
        }
    }

    @ViewBuilder private var sourcePane: some View {
        VStack(spacing: 0) {
            if let model, model.loadErrorReason == .unparseable, let error = model.loadError {
                parseErrorBanner(message: error)
                Divider()
            }
            TextEditor(text: $fileEditor.text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
        }
    }

    /// Compiler diagnostic banner shown atop the Source tab when the Design pane couldn't parse
    /// the component (see `sourcePane`). Unlike `conflictBanner`/`writeErrorBanner` it has no
    /// dismiss button — it stays until the underlying syntax error is fixed and the component
    /// reloads clean.
    private func parseErrorBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
        }
        .padding(8)
        .background(.red.opacity(0.12))
    }

    @ViewBuilder private var designPane: some View {
        if let model {
            if let error = model.loadError {
                if case .notConnected = model.loadErrorReason {
                    // Dev server isn't up yet — not a hard failure. `loadKey`
                    // re-fires this view's `.task` once `context.baseURL`
                    // transitions to non-nil, which retries the load; this
                    // is the interim state, matching the canvas's own
                    // "Dev Server Starting…" placeholder rather than an
                    // error page.
                    ContentUnavailableView("Dev Server Starting…", systemImage: "hourglass")
                } else {
                    ContentUnavailableView("Can't Open Component", systemImage: "exclamationmark.triangle", description: Text(error))
                }
            } else if model.isLoading || model.model == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    outline(model).frame(minWidth: 180, idealWidth: 220)
                    canvas(model).frame(minWidth: 320).layoutPriority(1)
                    inspector(model).frame(minWidth: 220, idealWidth: 260)
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func outline(_ model: ComponentEditorModel) -> some View {
        VStack(spacing: 0) {
            List(model.outlineRows, selection: Binding(
                get: { model.selectedNodeID },
                set: { model.selectedNodeID = $0 }
            )) { row in
                outlineRow(model, row: row)
                    .tag(row.node.id)
            }
            .listStyle(.sidebar)
            Divider()
            paletteView(model)
                .frame(height: 160)
        }
    }

    private func outlineRow(_ model: ComponentEditorModel, row: ComponentOutline.Row) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon(for: row.node.kind))
                .foregroundStyle(.secondary)
            Text(label(for: row.node))
            if row.isSealed {
                Spacer()
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.tertiary)
                    .help("Contains slot-fill content — double-click to edit \(row.node.tag ?? "this component")")
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .contentShape(Rectangle())
        .draggable(OutlineDragPayload.move(ComponentDragItem(fileID: model.relativePath, nodeID: row.node.id)))
        .dropDestination(for: OutlineDragPayload.self) { items, location in
            guard let item = items.first else { return false }
            switch item {
            case .move(let dragItem):
                guard dragItem.fileID == model.relativePath, dragItem.nodeID != row.node.id else { return false }
                Task { await performMove(model, draggedNodeID: dragItem.nodeID, targetRow: row, location: location) }
                return true
            case .insert(let payload):
                Task { await performInsert(model, payload: payload, targetRow: row, location: location) }
                return true
            }
        }
        .onTapGesture(count: 2) {
            guard row.isSealed else { return }
            openSealedComponent(model, row: row)
        }
    }

    /// Top third of the row = insert before (same parent as the target); bottom third =
    /// insert after (same parent); middle third = reparent as the target's last child.
    /// Pure geometry lives in `ComponentOutline.dropZone` (testable in Core); this wrapper
    /// additionally redirects a sealed row's middle third to `.after` — the outline hides a
    /// sealed component instance's slot-fill children (spec §4.1), so an `.into` drop there
    /// would silently vanish (it lands as markup with nowhere to render).
    private func dropZone(at location: CGPoint, for row: ComponentOutline.Row) -> ComponentOutline.DropZone {
        let zone = ComponentOutline.dropZone(y: Double(location.y))
        if row.isSealed && zone == .into { return .after }
        return zone
    }

    private func performMove(_ model: ComponentEditorModel, draggedNodeID: String, targetRow: ComponentOutline.Row, location: CGPoint) async {
        guard let dragged = model.outlineRows.first(where: { $0.node.id == draggedNodeID }) else { return }
        // Refuse a reparent that would create a structural cycle — dragging a node onto (or
        // before/after within) its own subtree. `performMove`'s only prior self-drop guard was
        // `dragItem.nodeID != row.node.id` in `outlineRow`, which doesn't catch a *descendant*.
        guard let root = model.model?.template, !ComponentOutline.isNodeOrDescendant(targetRow.node.id, of: dragged.node.id, in: root) else { return }
        switch dropZone(at: location, for: targetRow) {
        case .into:
            let targetChildCount = targetRow.node.children.count
            await model.moveNode(nodeId: dragged.node.id, newParentId: targetRow.node.id, newIndex: targetChildCount)
        case .before, .after:
            guard let parentID = parentID(of: targetRow.node.id, in: model), let siblingIndex = childIndex(of: targetRow.node.id, underParent: parentID, in: model) else { return }
            let zone = dropZone(at: location, for: targetRow)
            let targetIndex = zone == .before ? siblingIndex : siblingIndex + 1
            let draggedIndex = childIndex(of: dragged.node.id, underParent: parentID, in: model)
            let newIndex = ComponentOutline.adjustedMoveIndex(targetIndex: targetIndex, draggedIndex: draggedIndex)
            await model.moveNode(nodeId: dragged.node.id, newParentId: parentID, newIndex: newIndex)
        }
    }

    private func performInsert(_ model: ComponentEditorModel, payload: PaletteDragPayload, targetRow: ComponentOutline.Row, location: CGPoint) async {
        switch dropZone(at: location, for: targetRow) {
        case .into:
            await model.insertNode(parentId: targetRow.node.id, index: targetRow.node.children.count, node: payload.kind)
        case .before, .after:
            guard let parentID = parentID(of: targetRow.node.id, in: model), let siblingIndex = childIndex(of: targetRow.node.id, underParent: parentID, in: model) else { return }
            let zone = dropZone(at: location, for: targetRow)
            let index = zone == .before ? siblingIndex : siblingIndex + 1
            await model.insertNode(parentId: parentID, index: index, node: payload.kind)
        }
    }

    /// Finds `nodeID`'s parent id by walking `model.model?.template` — the outline's flat `Row`
    /// list doesn't carry parent links (per `ComponentOutline.Row`'s shape). Delegates the
    /// actual walk to `ComponentOutline` (testable in Core); this wrapper just resolves the
    /// tree root from the model.
    private func parentID(of nodeID: String, in model: ComponentEditorModel) -> String? {
        guard let root = model.model?.template else { return nil }
        return ComponentOutline.parentID(of: nodeID, in: root)
    }

    private func childIndex(of nodeID: String, underParent parentID: String, in model: ComponentEditorModel) -> Int? {
        guard let root = model.model?.template else { return nil }
        return ComponentOutline.childIndex(of: nodeID, underParent: parentID, in: root)
    }

    private func openSealedComponent(_ model: ComponentEditorModel, row: ComponentOutline.Row) {
        model.openReferencedComponent(tag: row.node.tag)
    }

    private func paletteView(_ model: ComponentEditorModel) -> some View {
        let items = ComponentPalette.items(projectComponents: model.projectComponents, excluding: model.file)
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 8) {
                ForEach(items) { item in
                    VStack(spacing: 2) {
                        Image(systemName: item.systemImage)
                        Text(item.label).font(.caption2).lineLimit(1)
                    }
                    .frame(width: 84, height: 44)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .draggable(OutlineDragPayload.insert(PaletteDragPayload(label: item.label, kind: item.kind)))
                    .contextMenu {
                        if case .component(_, let componentPath) = item.kind {
                            Button("Duplicate & Modify") {
                                Task { await model.duplicateComponent(path: componentPath) }
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    /// Device-width preset row above the canvas (design spec §3: "A viewport-width control
    /// (device presets + free resize)…"). "Free resize" isn't implemented in this pass — the
    /// four fixed presets are the "polish" scope issue #495 asks for; a drag handle can follow
    /// as its own increment if needed.
    private var viewportToolbar: some View {
        HStack(spacing: 2) {
            ForEach(ComponentViewportPreset.allCases) { preset in
                Button {
                    viewportPreset = preset
                } label: {
                    Image(systemName: preset.systemImage)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(viewportPreset == preset ? Color.accentColor : Color.secondary)
                .help(preset.label)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder private func canvas(_ model: ComponentEditorModel) -> some View {
        VStack(spacing: 0) {
            viewportToolbar
            Divider()
            if let props = model.model?.frontmatter?.props, !props.isEmpty {
                knobsBar(model, props: props)
                Divider()
            }
            canvasWebView(model)
        }
    }

    /// The harness `WKWebView` itself (drop-destination wiring unchanged from before slice 5a),
    /// width-constrained to `viewportPreset.width` when a fixed preset is active. `.fill`
    /// (`width == nil`) renders identically to the pre-slice-5 behavior — no frame constraint,
    /// canvas fills the available pane width.
    @ViewBuilder private func canvasWebView(_ model: ComponentEditorModel) -> some View {
        // Gated directly on `context.baseURL` (not just `model.harnessURL`)
        // so the live canvas replaces this placeholder the moment the dev
        // server becomes ready, in lockstep with the `loadKey`-driven
        // reload above.
        if context.baseURL != nil, let url = model.harnessURL {
            let content = ComponentCanvasView(
                url: url,
                editRouter: context.editRouter,
                onSelection: { model.canvasSelected($0) },
                onComputedStyles: { model.computedStyles = $0.styles },
                onWebView: { webView = $0 }
            )
            .dropDestination(for: OutlineDragPayload.self) { items, location in
                guard let item = items.first, case .insert(let payload) = item, let webView else { return false }
                Task { await performCanvasDrop(model, payload: payload, location: location, webView: webView) }
                return true
            }
            if let width = viewportPreset.width {
                // Sizes to the split pane's own available height (via GeometryReader) rather
                // than a fixed magic number — a hardcoded height either clipped the canvas on a
                // pane shorter than it, or left dead space below it on a taller one (PR #795
                // review). Horizontal scroll still covers the width-overflow case (preset wider
                // than the pane), which is the whole point of a fixed-width preset.
                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        content.frame(width: width, height: geometry.size.height)
                    }
                }
            } else {
                content
            }
        } else {
            ContentUnavailableView("Dev Server Starting…", systemImage: "hourglass")
        }
    }

    /// Resolves a canvas drop point to an insertion target via the overlay's `dropTargetAt`,
    /// then maps that source location back to a node id the same way `canvasSelected` does
    /// (`ComponentOutline.node(atLine:column:)`), and issues an `insert-node` at the resolved
    /// parent/index.
    private func performCanvasDrop(_ model: ComponentEditorModel, payload: PaletteDragPayload, location: CGPoint, webView: WKWebView) async {
        let script = "JSON.stringify(window.anglesiteCanvas?.dropTargetAt?.(\(location.x), \(location.y)) ?? null)"
        guard let raw = try? await webView.evaluateJavaScript(script) as? String,
              let data = raw.data(using: .utf8),
              let target = try? JSONDecoder().decode(DropTargetPayload.self, from: data),
              let modelRoot = model.model?.template,
              let node = ComponentOutline.node(atLine: target.line, column: target.column, in: modelRoot)
        else { return }

        // Same sealed-instance redirect as the outline path (`dropZone(at:for:)`): the JS
        // overlay's zone geometry has no notion of sealed component instances, so a canvas drop
        // squarely on a `<Hcard />`-style instance would otherwise land as invisible slot-fill
        // content the outline can never render.
        let zone = (node.kind == .component && target.zone == "into") ? "after" : target.zone
        switch zone {
        case "into":
            await model.insertNode(parentId: node.id, index: node.children.count, node: payload.kind)
        case "before", "after":
            guard let parentID = parentID(of: node.id, in: model), let siblingIndex = childIndex(of: node.id, underParent: parentID, in: model) else { return }
            let index = zone == "before" ? siblingIndex : siblingIndex + 1
            await model.insertNode(parentId: parentID, index: index, node: payload.kind)
        default:
            break
        }
    }

    private struct DropTargetPayload: Decodable {
        let file: String?
        let line: Int
        let column: Int
        let zone: String
    }

    /// Stable dictionary/Set key for a media group — `""` for the unscoped "Base styles" group,
    /// the media condition string otherwise. Mirrors `ComponentStyleGrouping.groups`' own
    /// `key.isEmpty ? nil : key` convention so the two stay in sync.
    private func mediaGroupKey(_ media: String?) -> String { media ?? "" }

    /// Expand/collapse binding for one media group's `DisclosureGroup`, backed by
    /// `collapsedMediaKeys` — defaults to expanded (absent from the set) so the panel reads the
    /// same as the old always-expanded flat list until the user explicitly collapses a section.
    private func mediaExpandedBinding(for media: String?) -> Binding<Bool> {
        let key = mediaGroupKey(media)
        return Binding(
            get: { !collapsedMediaKeys.contains(key) },
            set: { expanded in
                if expanded {
                    collapsedMediaKeys.remove(key)
                } else {
                    collapsedMediaKeys.insert(key)
                }
            }
        )
    }

    /// One rule's editable selector + declaration rows — extracted from the old flat Styles
    /// rendering so the grouped-by-media rendering above can reuse it per group.
    @ViewBuilder
    private func ruleRow(_ model: ComponentEditorModel, ruleIndex: Int, rule: ComponentModel.StyleRule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("selector", text: selectorBinding(for: rule))
                .font(.system(.caption, design: .monospaced))
                .textFieldStyle(.plain)
                .bold()
                .onSubmit { commitSelector(model, rule: rule) }
            ForEach(rule.declarations, id: \.property) { decl in
                HStack(spacing: 4) {
                    TextField("property", text: propertyBinding(for: decl))
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.plain)
                        .frame(width: 110)
                        .onSubmit { commitDeclaration(model, ruleIndex: ruleIndex, rule: rule, decl: decl) }
                    Text(":")
                    declarationValueField(model, ruleIndex: ruleIndex, rule: rule, decl: decl)
                    Button(role: .destructive) {
                        removeDeclaration(model, rule: rule, decl: decl)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Add declaration") {
                let newProperty = "new-property-\(UUID().uuidString.prefix(8))"
                Task { await model.setStyleProperty(ruleSpan: spanArray(rule.span), property: newProperty, value: "") }
            }
            .font(.caption2)
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func knobsBar(_ model: ComponentEditorModel, props: [ComponentModel.Prop]) -> some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(props, id: \.name) { prop in
                    LabeledContent(prop.name) {
                        knobControl(model, prop: prop)
                    }
                }
            }
            .padding(8)
        }
    }

    /// Type-aware harness knob control (design spec §4.2): a `boolean` prop gets a `Toggle`,
    /// a `number` prop gets a `Stepper` alongside its text field, and everything else keeps the
    /// plain text field slice 1 shipped. `model.knobValues` stays `[String: String]` regardless
    /// (that's `HarnessURL.build`'s contract) — these controls just read/write it through a
    /// typed `Binding`.
    @ViewBuilder
    private func knobControl(_ model: ComponentEditorModel, prop: ComponentModel.Prop) -> some View {
        switch prop.type {
        case "boolean":
            Toggle("", isOn: booleanKnobBinding(model, name: prop.name))
                .labelsHidden()
        case "number":
            HStack(spacing: 2) {
                TextField(prop.type, text: knobBinding(model, name: prop.name))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Stepper("", value: numberKnobBinding(model, name: prop.name))
                    .labelsHidden()
            }
        default:
            TextField(prop.type, text: knobBinding(model, name: prop.name))
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
        }
    }

    private func knobBinding(_ model: ComponentEditorModel, name: String) -> Binding<String> {
        Binding(
            get: { model.knobValues[name] ?? "" },
            set: { model.knobValues[name] = $0 }
        )
    }

    private func booleanKnobBinding(_ model: ComponentEditorModel, name: String) -> Binding<Bool> {
        Binding(
            get: { (model.knobValues[name] ?? "false") == "true" },
            set: { model.knobValues[name] = $0 ? "true" : "false" }
        )
    }

    private func numberKnobBinding(_ model: ComponentEditorModel, name: String) -> Binding<Double> {
        Binding(
            get: { Double(model.knobValues[name] ?? "") ?? 0 },
            set: { model.knobValues[name] = formatKnobNumber($0) }
        )
    }

    /// Drops a redundant trailing ".0" for whole numbers so an integer-typed prop's knob (e.g.
    /// `count`) round-trips as "2", not "2.0".
    private func formatKnobNumber(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
    }

    private func inspector(_ model: ComponentEditorModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let node = model.selectedNode {
                    GroupBox("Selection") {
                        LabeledContent("Kind", value: node.kind.rawValue)
                        if let tag = node.tag { LabeledContent("Tag", value: tag) }
                        ForEach(node.attrs, id: \.name) { attr in
                            HStack(spacing: 4) {
                                Text(attr.name).font(.system(.caption, design: .monospaced)).frame(width: 90, alignment: .leading)
                                TextField("value", text: attrValueBinding(model, node: node, name: attr.name))
                                    .font(.system(.caption, design: .monospaced))
                                    .textFieldStyle(.plain)
                                    .onSubmit { commitAttr(model, node: node, name: attr.name) }
                                Button(role: .destructive) {
                                    removeAttr(model, node: node, name: attr.name)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        HStack {
                            TextField("New attribute name", text: $newAttrName)
                                .font(.system(.caption, design: .monospaced))
                            TextField("value", text: $newAttrValue)
                                .font(.system(.caption, design: .monospaced))
                            Button("Add") {
                                let name = newAttrName.trimmingCharacters(in: .whitespaces)
                                guard !name.isEmpty else { return }
                                Task {
                                    await model.setAttr(nodeId: node.id, name: name, value: newAttrValue)
                                    newAttrName = ""
                                    newAttrValue = ""
                                }
                            }
                            .disabled(newAttrName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                propsForm(model)
                codePane(model)
                if model.conflict {
                    conflictBanner(model)
                }
                if let writeError = model.writeError {
                    writeErrorBanner(model, message: writeError)
                }
                GroupBox("Styles") {
                    if let styles = model.model?.styles, !styles.isEmpty {
                        let groups = ComponentStyleGrouping.groups(from: styles)
                        ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
                            DisclosureGroup(isExpanded: mediaExpandedBinding(for: group.media)) {
                                ForEach(Array(group.rules.enumerated()), id: \.element.index) { position, indexed in
                                    ruleRow(model, ruleIndex: indexed.index, rule: indexed.rule)
                                    if position < group.rules.count - 1 {
                                        Divider()
                                    }
                                }
                            } label: {
                                Text(group.media.map { "@media \($0)" } ?? "Base styles")
                                    .font(.caption).bold()
                            }
                            if groupIndex < groups.count - 1 {
                                Divider()
                            }
                        }
                    } else {
                        Text("No scoped styles").foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("New selector, e.g. .card-footer", text: $newRuleSelector)
                                .font(.system(.caption, design: .monospaced))
                            TextField("Condition, e.g. (min-width: 768px)", text: $newRuleMedia)
                                .font(.system(.caption, design: .monospaced))
                        }
                        Button("Add rule") {
                            let selector = newRuleSelector.trimmingCharacters(in: .whitespaces)
                            guard !selector.isEmpty else { return }
                            let media = ComponentStyleGrouping.normalizeMediaCondition(newRuleMedia)
                            Task {
                                await model.addStyleRule(selector: selector, media: media.isEmpty ? nil : media, declarations: [])
                                newRuleSelector = ""
                                newRuleMedia = ""
                            }
                        }
                        .disabled(newRuleSelector.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                GroupBox("Computed") {
                    if model.computedStyles.isEmpty {
                        Text("Select an element in the canvas").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.computedStyles.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            LabeledContent(key, value: value)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    /// Structured Props form (design spec §4.3): the component's `Props` interface as
    /// name/type/optional/default rows, independent of outline selection — props belong to the
    /// component as a whole, not to any one template node. Edits accumulate in `propsDraft` and
    /// commit together via "Save Props" (a `set-props-interface` op replaces the whole
    /// interface atomically, so there's no single field to auto-commit on blur/submit the way
    /// the Styles panel's declaration rows do).
    private func propsForm(_ model: ComponentEditorModel) -> some View {
        GroupBox("Props") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach($propsDraft) { $prop in
                    HStack(spacing: 4) {
                        TextField("name", text: $prop.name)
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 80)
                        TextField("type", text: $prop.type)
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 70)
                        Toggle("optional", isOn: $prop.optional)
                            .labelsHidden()
                            .help("Optional")
                        TextField("default", text: $prop.defaultValue)
                            .font(.system(.caption, design: .monospaced))
                        Button(role: .destructive) {
                            propsDraft.removeAll { $0.id == prop.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    Button("Add Prop") {
                        propsDraft.append(PropDraft(name: "", type: "string", optional: false, defaultValue: ""))
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    Spacer()
                    Button("Save Props") {
                        Task { await savePropsDraft(model) }
                    }
                    .disabled(!propsDraftDirty(model))
                }
            }
        }
    }

    /// True when `propsDraft` differs from the current model's props — gates "Save Props" so it
    /// only enables once there's something to save (and disables again once the piggybacked
    /// model from a successful save re-seeds the draft via the `.onChange(of: model?.model?.version)`
    /// handler in `body`).
    private func propsDraftDirty(_ model: ComponentEditorModel) -> Bool {
        propsDraft != (model.model?.frontmatter?.props ?? []).map(PropDraft.init)
    }

    /// Commits `propsDraft` via `setPropsInterface`, dropping any row with a blank name or type
    /// (an in-progress "Add Prop" row the user hasn't filled in yet) rather than sending it as a
    /// malformed prop the plugin would refuse outright.
    private func savePropsDraft(_ model: ComponentEditorModel) async {
        let props = propsDraft.compactMap { draft -> ComponentModel.Prop? in
            let name = draft.name.trimmingCharacters(in: .whitespaces)
            let type = draft.type.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !type.isEmpty else { return nil }
            let defaultValue = draft.defaultValue.trimmingCharacters(in: .whitespaces)
            return ComponentModel.Prop(name: name, type: type, optional: draft.optional, defaultValue: defaultValue.isEmpty ? nil : defaultValue)
        }
        await model.setPropsInterface(props: props)
    }

    /// The two STTextView code panes (design spec §4.3/§7): "Props & Data" (frontmatter TS) and
    /// "Behavior" (client script), tree-sitter highlighted, switched with a segmented picker.
    /// Dirty-tracked like `FileEditorModel` — explicit save via the button below, not on blur
    /// (see that button's doc comment for why it doesn't also bind ⌘S).
    private func codePane(_ model: ComponentEditorModel) -> some View {
        GroupBox("Code") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Zone", selection: $codeZone) {
                    ForEach(CodeZone.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // `.id(codeZone)` forces SwiftUI to tear down and recreate this
                // NSViewRepresentable (fresh Coordinator, fresh STTextView, fresh NeonPlugin) on
                // every tab switch, rather than reusing the same underlying view/coordinator
                // across zones. Without it, `makeCoordinator`/`makeNSView` run exactly once for
                // the lifetime of this view's position in the tree: the coordinator's captured
                // `text` binding and the plugin's `language` would both stay pinned to whichever
                // zone was active at first mount, so typing after switching tabs would silently
                // write into the wrong zone's draft and highlight with the wrong grammar (PR
                // #774 review). Recreating the view on zone change does mean losing cursor/scroll
                // position when switching tabs — an acceptable tradeoff over misrouted edits.
                ComponentCodeEditorView(
                    text: codeDraftBinding(codeZone),
                    language: codeZone.language
                )
                .id(codeZone)
                .frame(height: 160)
                .border(.separator)
                HStack {
                    if codeDraftDirty(model, zone: codeZone) {
                        Text("Unsaved changes").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Save") {
                        Task { await saveCodeDraft(model, zone: codeZone) }
                    }
                    // No local ⌘S: `SaveCommands`/#509 centralized File ▸ Save specifically to
                    // avoid double-registering the shortcut when multiple editing surfaces are
                    // on screen at once. This pane isn't wired into `SiteWindowModel.activeEditor`
                    // (a closed `.text`/`.plist` enum) yet — a reasonable follow-up once the
                    // Component Editor's props/code drafts need to participate in File ▸ Save /
                    // Revert to Saved the way the main-pane editor and inspector already do.
                    .disabled(!codeDraftDirty(model, zone: codeZone))
                }
            }
        }
    }

    private func codeDraftBinding(_ zone: CodeZone) -> Binding<String> {
        Binding(
            get: { codeDrafts[zone] ?? "" },
            set: { codeDrafts[zone] = $0 }
        )
    }

    private func currentZoneSource(_ model: ComponentEditorModel, zone: CodeZone) -> String {
        switch zone {
        case .frontmatter: model.model?.frontmatter?.source ?? ""
        case .client: model.model?.clientScript?.source ?? ""
        }
    }

    private func codeDraftDirty(_ model: ComponentEditorModel, zone: CodeZone) -> Bool {
        (codeDrafts[zone] ?? "") != currentZoneSource(model, zone: zone)
    }

    private func saveCodeDraft(_ model: ComponentEditorModel, zone: CodeZone) async {
        await model.setScriptZone(zone: zone.rawValue, source: codeDrafts[zone] ?? "")
    }

    /// "This component changed outside Anglesite" banner — the edit that triggered a stale-write
    /// refusal was never applied; `ComponentEditorModel.applyComponentStyleEdit` already reloaded
    /// the latest version, so this just informs the user why their change didn't stick.
    private func conflictBanner(_ model: ComponentEditorModel) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
            Text("This component changed outside Anglesite — your edit wasn't applied, reloaded the latest version.")
                .font(.caption)
            Spacer()
            Button {
                model.conflict = false
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Transient, non-fatal banner for a style write op that failed for a reason other than
    /// staleness (invalid value, drifted `ruleSpan`, transient MCP error). Scoped to the Styles
    /// panel so a routine write failure never takes over the whole editor pane (see
    /// `ComponentEditorModel.writeError`'s doc comment).
    private func writeErrorBanner(_ model: ComponentEditorModel, message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
            Text(message).font(.caption)
            Spacer()
            Button {
                model.writeError = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private func highlightInCanvas(nodeID: String?) {
        guard let webView, let model else { return }
        guard let nodeID,
              let node = model.outlineRows.first(where: { $0.node.id == nodeID })?.node,
              let loc = node.loc
        else {
            webView.evaluateJavaScript("window.anglesiteCanvas?.clear?.()")
            return
        }
        webView.evaluateJavaScript("window.anglesiteCanvas?.highlight?.(\(loc.line), \(loc.column))")
    }

    private func icon(for kind: ComponentModel.Node.Kind) -> String {
        switch kind {
        case .fragment: "square.dashed"
        case .element: "chevron.left.forwardslash.chevron.right"
        case .component: "puzzlepiece.extension"
        case .expression: "curlybraces"
        case .slot: "tray"
        case .text: "text.alignleft"
        }
    }

    private func label(for node: ComponentModel.Node) -> String {
        switch node.kind {
        case .text: node.text ?? "text"
        case .expression: "{…}"
        default: node.tag ?? node.kind.rawValue
        }
    }

    // MARK: - Styles panel editing

    /// `ComponentModel.Span` isn't `CustomStringConvertible`, so build a
    /// stable dictionary key from its optional start/end offsets directly.
    private func spanKey(_ span: ComponentModel.Span) -> String {
        "\(span.start ?? -1)-\(span.end ?? -1)"
    }

    /// Escapes a Swift string into a double-quoted JS string literal for
    /// interpolation into `evaluateJavaScript` call sites.
    private func jsStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func spanArray(_ span: ComponentModel.Span) -> [Int?] {
        [span.start, span.end]
    }

    private func selectorBinding(for rule: ComponentModel.StyleRule) -> Binding<String> {
        let key = spanKey(rule.span)
        return Binding(
            get: { selectorDrafts[key] ?? rule.selector },
            set: { selectorDrafts[key] = $0 }
        )
    }

    private func attrValueBinding(_ model: ComponentEditorModel, node: ComponentModel.Node, name: String) -> Binding<String> {
        let key = "\(node.id):\(name)"
        let current = node.attrs.first(where: { $0.name == name })?.value ?? ""
        return Binding(
            get: { attrValueDrafts[key] ?? current },
            set: { attrValueDrafts[key] = $0 }
        )
    }

    private func commitAttr(_ model: ComponentEditorModel, node: ComponentModel.Node, name: String) {
        let key = "\(node.id):\(name)"
        guard let draft = attrValueDrafts[key] else { return }
        let current = node.attrs.first(where: { $0.name == name })?.value ?? ""
        guard draft != current else { return }
        Task { await model.setAttr(nodeId: node.id, name: name, value: draft) }
    }

    /// Discards any in-progress draft for `name` before removing the attribute. Without this, a
    /// stale draft (typed but never submitted) would linger in `attrValueDrafts` and resurface if
    /// the same attribute name is later re-added via "Add attribute" — `attrValueBinding`'s getter
    /// would render the discarded draft instead of the freshly-committed value, and submitting it
    /// would silently overwrite the new value. Mirrors `removeDeclaration`'s draft-clearing.
    private func removeAttr(_ model: ComponentEditorModel, node: ComponentModel.Node, name: String) {
        attrValueDrafts["\(node.id):\(name)"] = nil
        Task { await model.setAttr(nodeId: node.id, name: name, value: nil) }
    }

    private func propertyBinding(for decl: ComponentModel.Declaration) -> Binding<String> {
        let key = spanKey(decl.span)
        return Binding(
            get: { propertyDrafts[key] ?? decl.property },
            set: { propertyDrafts[key] = $0 }
        )
    }

    @ViewBuilder
    private func declarationValueField(
        _ model: ComponentEditorModel,
        ruleIndex: Int,
        rule: ComponentModel.StyleRule,
        decl: ComponentModel.Declaration
    ) -> some View {
        let key = spanKey(decl.span)
        let valueBinding = Binding(
            get: { valueDrafts[key] ?? decl.value },
            set: { valueDrafts[key] = $0 }
        )
        HStack(spacing: 4) {
            TextField("value", text: valueBinding)
                .font(.system(.caption, design: .monospaced))
                .textFieldStyle(.plain)
                .onSubmit { commitDeclaration(model, ruleIndex: ruleIndex, rule: rule, decl: decl) }
            if CSSColor.colorProperties.contains(decl.property),
               let color = CSSColor.parse(valueBinding.wrappedValue) {
                ColorPicker("", selection: Binding(
                    get: { color },
                    set: { newColor in
                        let formatted = CSSColor.format(newColor)
                        valueDrafts[key] = formatted
                        webView?.evaluateJavaScript(
                            "window.anglesiteCanvas?.scrub?.(\(jsStringLiteral(rule.selector)), \(jsStringLiteral(decl.property)), \(jsStringLiteral(formatted)))"
                        )
                        debounceColorCommit(key, model, ruleIndex: ruleIndex, rule: rule, decl: decl)
                    }
                ))
                .labelsHidden()
            }
        }
    }

    /// Debounces `ColorPicker` writes: cancels any pending commit for this declaration and
    /// schedules a new one after a short pause, so only the settled value after a drag gesture
    /// actually calls `commitDeclaration` (see `colorCommitTasks` doc comment).
    private func debounceColorCommit(
        _ key: String,
        _ model: ComponentEditorModel,
        ruleIndex: Int,
        rule: ComponentModel.StyleRule,
        decl: ComponentModel.Declaration
    ) {
        colorCommitTasks[key]?.cancel()
        colorCommitTasks[key] = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            commitDeclaration(model, ruleIndex: ruleIndex, rule: rule, decl: decl)
            _ = try? await webView?.evaluateJavaScript("window.anglesiteCanvas?.clearScrub?.()")
            colorCommitTasks[key] = nil
        }
    }

    private func commitSelector(_ model: ComponentEditorModel, rule: ComponentModel.StyleRule) {
        let key = spanKey(rule.span)
        let newSelector = selectorDrafts[key] ?? rule.selector
        guard newSelector != rule.selector else { return }
        Task { await model.setRuleSelector(ruleSpan: spanArray(rule.span), newSelector: newSelector) }
    }

    /// Cancels any pending debounced `ColorPicker` commit and discards the in-progress drafts
    /// for `decl` before removing it. Without this, a declaration removed mid-drag (before the
    /// `debounceColorCommit` delay elapses) would have its pending commit fire afterward and
    /// resurrect the just-deleted declaration via `setStyleProperty`.
    private func removeDeclaration(
        _ model: ComponentEditorModel,
        rule: ComponentModel.StyleRule,
        decl: ComponentModel.Declaration
    ) {
        let key = spanKey(decl.span)
        colorCommitTasks[key]?.cancel()
        colorCommitTasks[key] = nil
        valueDrafts[key] = nil
        propertyDrafts[key] = nil
        Task { await model.removeStyleProperty(ruleSpan: spanArray(rule.span), property: decl.property) }
    }

    /// Commits both the property-name and value drafts for a declaration.
    /// Called from either field's `onSubmit` so an edit to just the property
    /// name (value unchanged) still lands, not only edits to the value field.
    ///
    /// A property rename is a remove-then-add sequence against the *same* rule: removing the
    /// old declaration shifts byte offsets within the file (including, in general, the rule's
    /// own end offset), so the second write must target the rule's freshly reloaded span, not
    /// the one captured before either op ran — reusing the stale span would make the add
    /// mismatch or fail outright on essentially every rename. `ruleIndex` (the rule's stable
    /// ordinal position — these two ops never add/remove/reorder rules) is used to re-derive
    /// the fresh span from `model.model` after the remove completes. If the remove itself
    /// failed, the rename is abandoned rather than adding the new name anyway, which would
    /// otherwise leave both the old and new declarations present.
    private func commitDeclaration(
        _ model: ComponentEditorModel,
        ruleIndex: Int,
        rule: ComponentModel.StyleRule,
        decl: ComponentModel.Declaration
    ) {
        let key = spanKey(decl.span)
        let property = propertyDrafts[key] ?? decl.property
        let value = valueDrafts[key] ?? decl.value
        guard property != decl.property || value != decl.value else { return }
        let ruleSpan = spanArray(rule.span)
        let oldProperty = decl.property
        if property != oldProperty {
            Task {
                let removed = await model.removeStyleProperty(ruleSpan: ruleSpan, property: oldProperty)
                guard removed else { return }
                let freshSpan = model.ruleSpan(atIndex: ruleIndex).map(spanArray) ?? ruleSpan
                await model.setStyleProperty(ruleSpan: freshSpan, property: property, value: value)
            }
        } else {
            Task { await model.setStyleProperty(ruleSpan: ruleSpan, property: property, value: value) }
        }
    }
}

/// Harness-page WKWebView: same bridge as the preview, wired to the
/// component-canvas handlers. Routes edits (e.g. a Styles panel change)
/// through `editRouter` when the site window has wired one up;
/// falls back to `LoggingEditRouter()` — logs to the Debug pane instead of
/// applying — when it hasn't (dev server not started yet, or a context that
/// intentionally has no write capability).
private struct ComponentCanvasView: NSViewRepresentable {
    let url: URL
    var editRouter: EditRouter?
    let onSelection: @MainActor (CanvasSelectionMessage) -> Void
    let onComputedStyles: @MainActor (ComputedStylesReport) -> Void
    var onWebView: (WKWebView) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var loadedURL: URL?
        /// Debounces reloads triggered by rapid `url` changes (e.g. a knob TextField's
        /// per-keystroke `harnessURL`, which folds prop edits into the query string) so each
        /// keystroke doesn't fire a full `webView.load()`. Cancelled and restarted on every
        /// further change; only the settled URL after a short pause actually reloads.
        var pendingReload: Task<Void, Never>?
    }

    func makeNSView(context: Context) -> WKWebView {
        let onSelection = self.onSelection
        let onComputedStyles = self.onComputedStyles
        let handler = AnglesiteScriptHandler(
            router: resolveEditRouter(editRouter),
            onCanvasSelection: { message in await MainActor.run { onSelection(message) } },
            onComputedStyles: { report in await MainActor.run { onComputedStyles(report) } }
        )
        let configuration = WebViewBridge.localDevConfiguration(handler: handler)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        WebViewBridge.applyPreviewDefaults(to: webView)
        webView.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
        onWebView(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        let targetURL = url
        let coordinator = context.coordinator
        coordinator.pendingReload?.cancel()
        coordinator.pendingReload = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            coordinator.loadedURL = targetURL
            coordinator.pendingReload = nil
            webView.load(URLRequest(url: targetURL))
        }
    }
}

/// STTextView-backed code pane for a component script zone, tree-sitter highlighted via
/// STTextView-Plugin-Neon's `NeonPlugin`. Wraps the AppKit view directly
/// (`STTextView.scrollableTextView()`), matching `ComponentCanvasView` above's own
/// NSViewRepresentable-over-AppKit pattern rather than STTextView's SwiftUI wrapper.
private struct ComponentCodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let language: TreeSitterLanguage

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    final class Coordinator: NSObject, STTextViewDelegate {
        let text: Binding<String>
        /// Set while `updateNSView` is pushing the SwiftUI-side value into the text view, so
        /// the resulting `textViewDidChangeText` notification doesn't bounce right back into
        /// `text` (a no-op, but one that would otherwise re-trigger `updateNSView` every frame).
        var isProgrammaticUpdate = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChangeText(_ notification: Notification) {
            guard !isProgrammaticUpdate, let textView = notification.object as? STTextView else { return }
            text.wrappedValue = textView.text ?? ""
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = STTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? STTextView else { return scrollView }
        textView.text = text
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.delegate = context.coordinator
        textView.addPlugin(NeonPlugin(theme: .default, language: language))
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? STTextView, textView.text != text else { return }
        context.coordinator.isProgrammaticUpdate = true
        textView.text = text
        context.coordinator.isProgrammaticUpdate = false
    }
}
