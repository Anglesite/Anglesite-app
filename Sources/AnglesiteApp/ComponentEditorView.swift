import SwiftUI
import WebKit
import AnglesiteCore
import AnglesiteBridge

/// Read-only Component Editor (slice 1): outline + harness canvas + inspector.
struct ComponentEditorView: View {
    let file: FileRef
    let context: ComponentEditorContext
    @Bindable var fileEditor: FileEditorModel

    @State private var model: ComponentEditorModel?
    /// Design (three-pane) vs Source (existing text editor) — the escape hatch.
    @State private var mode: Mode = .design
    @State private var webView: WKWebView?

    /// In-progress edits to a rule's selector, keyed by `spanKey(rule.span)`,
    /// pending commit (on focus loss) to `ComponentEditorModel.setRuleSelector`.
    @State private var selectorDrafts: [String: String] = [:]
    /// In-progress edits to a declaration's property name, keyed by
    /// `spanKey(decl.span)`, pending commit to `setStyleProperty`.
    @State private var propertyDrafts: [String: String] = [:]
    /// In-progress edits to a declaration's value, keyed by `spanKey(decl.span)`.
    @State private var valueDrafts: [String: String] = [:]

    enum Mode: String, CaseIterable { case design = "Design", source = "Source" }

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
            case .source:
                TextEditor(text: $fileEditor.text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
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
        List(model.outlineRows, selection: Binding(
            get: { model.selectedNodeID },
            set: { model.selectedNodeID = $0 }
        )) { row in
            HStack(spacing: 4) {
                Image(systemName: icon(for: row.node.kind))
                    .foregroundStyle(.secondary)
                Text(label(for: row.node))
            }
            .padding(.leading, CGFloat(row.depth) * 14)
            .tag(row.node.id)
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private func canvas(_ model: ComponentEditorModel) -> some View {
        VStack(spacing: 0) {
            if let props = model.model?.frontmatter?.props, !props.isEmpty {
                knobsBar(model, props: props)
                Divider()
            }
            // Gated directly on `context.baseURL` (not just `model.harnessURL`)
            // so the live canvas replaces this placeholder the moment the dev
            // server becomes ready, in lockstep with the `loadKey`-driven
            // reload above.
            if context.baseURL != nil, let url = model.harnessURL {
                ComponentCanvasView(
                    url: url,
                    editRouter: context.editRouter,
                    onSelection: { model.canvasSelected($0) },
                    onComputedStyles: { model.computedStyles = $0.styles },
                    onWebView: { webView = $0 }
                )
            } else {
                ContentUnavailableView("Dev Server Starting…", systemImage: "hourglass")
            }
        }
    }

    private func knobsBar(_ model: ComponentEditorModel, props: [ComponentModel.Prop]) -> some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(props, id: \.name) { prop in
                    LabeledContent(prop.name) {
                        TextField(prop.type, text: knobBinding(model, name: prop.name))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                }
            }
            .padding(8)
        }
    }

    private func knobBinding(_ model: ComponentEditorModel, name: String) -> Binding<String> {
        Binding(
            get: { model.knobValues[name] ?? "" },
            set: { model.knobValues[name] = $0 }
        )
    }

    private func inspector(_ model: ComponentEditorModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let node = model.selectedNode {
                    GroupBox("Selection") {
                        LabeledContent("Kind", value: node.kind.rawValue)
                        if let tag = node.tag { LabeledContent("Tag", value: tag) }
                        ForEach(node.attrs, id: \.name) { attr in
                            LabeledContent(attr.name, value: attr.value ?? "—")
                        }
                    }
                }
                GroupBox("Styles") {
                    if let styles = model.model?.styles, !styles.isEmpty {
                        ForEach(Array(styles.enumerated()), id: \.offset) { ruleIndex, rule in
                            VStack(alignment: .leading, spacing: 4) {
                                if let media = rule.media {
                                    Text("@media \(media)").font(.caption2).foregroundStyle(.secondary)
                                }
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
                                            .onSubmit { commitDeclaration(model, rule: rule, decl: decl) }
                                        Text(":")
                                        declarationValueField(model, rule: rule, decl: decl)
                                        Button(role: .destructive) {
                                            Task { await model.removeStyleProperty(ruleSpan: spanArray(rule.span), property: decl.property) }
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
                            if ruleIndex < styles.count - 1 {
                                Divider()
                            }
                        }
                    } else {
                        Text("No scoped styles").foregroundStyle(.secondary)
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
                .onSubmit { commitDeclaration(model, rule: rule, decl: decl) }
            if CSSColor.colorProperties.contains(decl.property),
               let color = CSSColor.parse(valueBinding.wrappedValue) {
                ColorPicker("", selection: Binding(
                    get: { color },
                    set: { newColor in
                        valueDrafts[key] = CSSColor.format(newColor)
                        commitDeclaration(model, rule: rule, decl: decl)
                    }
                ))
                .labelsHidden()
            }
        }
    }

    private func commitSelector(_ model: ComponentEditorModel, rule: ComponentModel.StyleRule) {
        let key = spanKey(rule.span)
        let newSelector = selectorDrafts[key] ?? rule.selector
        guard newSelector != rule.selector else { return }
        Task { await model.setRuleSelector(ruleSpan: spanArray(rule.span), newSelector: newSelector) }
    }

    /// Commits both the property-name and value drafts for a declaration.
    /// Called from either field's `onSubmit` so an edit to just the property
    /// name (value unchanged) still lands, not only edits to the value field.
    private func commitDeclaration(
        _ model: ComponentEditorModel,
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
                await model.removeStyleProperty(ruleSpan: ruleSpan, property: oldProperty)
                await model.setStyleProperty(ruleSpan: ruleSpan, property: property, value: value)
            }
        } else {
            Task { await model.setStyleProperty(ruleSpan: ruleSpan, property: property, value: value) }
        }
    }
}

/// Harness-page WKWebView: same bridge as the preview, wired to the
/// component-canvas handlers. Routes edits (e.g. a Styles panel change)
/// through `editRouter` when the site window has wired one up (slice 2);
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

    final class Coordinator {
        var loadedURL: URL?
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
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
    }
}
