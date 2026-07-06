import SwiftUI
import WebKit
import AnglesiteCore
import AnglesiteBridge

/// Read-only Component Editor (slice 1): outline + harness canvas + inspector.
struct ComponentEditorView: View {
    @State private var model: ComponentEditorModel
    /// Design (three-pane) vs Source (existing text editor) — the escape hatch.
    @State private var mode: Mode = .design
    @State private var webView: WKWebView?

    enum Mode: String, CaseIterable { case design = "Design", source = "Source" }

    let fileEditor: FileEditorModel

    init(file: FileRef, context: ComponentEditorContext, fileEditor: FileEditorModel) {
        _model = State(initialValue: ComponentEditorModel(file: file, context: context))
        self.fileEditor = fileEditor
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
                TextEditor(text: .constant(fileEditor.text))
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
            }
        }
        .task { await model.load() }
        .onChange(of: model.selectedNodeID) { _, newValue in
            highlightInCanvas(nodeID: newValue)
        }
    }

    @ViewBuilder private var designPane: some View {
        if let error = model.loadError {
            ContentUnavailableView("Can't Open Component", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if model.isLoading || model.model == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                outline.frame(minWidth: 180, idealWidth: 220)
                canvas.frame(minWidth: 320).layoutPriority(1)
                inspector.frame(minWidth: 220, idealWidth: 260)
            }
        }
    }

    private var outline: some View {
        List(model.outlineRows, selection: $model.selectedNodeID) { row in
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

    @ViewBuilder private var canvas: some View {
        VStack(spacing: 0) {
            if let props = model.model?.frontmatter?.props, !props.isEmpty {
                knobsBar(props: props)
                Divider()
            }
            if let url = model.harnessURL {
                ComponentCanvasView(
                    url: url,
                    onSelection: { model.canvasSelected($0) },
                    onComputedStyles: { model.computedStyles = $0.styles },
                    onWebView: { webView = $0 }
                )
            } else {
                ContentUnavailableView("Dev Server Starting…", systemImage: "hourglass")
            }
        }
    }

    private func knobsBar(props: [ComponentModel.Prop]) -> some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(props, id: \.name) { prop in
                    LabeledContent(prop.name) {
                        TextField(prop.type, text: knobBinding(prop.name))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                }
            }
            .padding(8)
        }
    }

    private func knobBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { model.knobValues[name] ?? "" },
            set: { model.knobValues[name] = $0 }
        )
    }

    private var inspector: some View {
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
        guard let webView else { return }
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
/// component-canvas handlers. No edit routing in slice 1.
private struct ComponentCanvasView: NSViewRepresentable {
    let url: URL
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
            router: LoggingEditRouter(),
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
