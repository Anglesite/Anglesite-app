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
                        ForEach(Array(styles.enumerated()), id: \.offset) { _, rule in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.media.map { "@media \($0)" } ?? "")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(rule.selector).font(.system(.caption, design: .monospaced)).bold()
                                ForEach(rule.declarations, id: \.property) { decl in
                                    Text("\(decl.property): \(decl.value);")
                                        .font(.system(.caption, design: .monospaced))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
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
            router: editRouter ?? LoggingEditRouter(),
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
