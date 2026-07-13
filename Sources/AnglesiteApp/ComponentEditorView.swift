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
    /// Pending debounced commit from a `ColorPicker` drag, keyed by `spanKey(decl.span)`.
    /// macOS `ColorPicker` updates its binding continuously while the system color panel is
    /// being dragged, so committing on every change would fire a burst of redundant
    /// `setStyleProperty` round-trips (and risk spurious `.failed`/stale-`baseVersion` conflicts).
    /// Each new picker value cancels the previous pending commit and restarts the delay, so only
    /// the settled value after the drag pauses actually commits.
    @State private var colorCommitTasks: [String: Task<Void, Never>] = [:]
    /// Selector text for the inline "Add rule" form at the bottom of the Styles panel.
    @State private var newRuleSelector: String = ""

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
                if model.conflict {
                    conflictBanner(model)
                }
                if let writeError = model.writeError {
                    writeErrorBanner(model, message: writeError)
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
                            if ruleIndex < styles.count - 1 {
                                Divider()
                            }
                        }
                    } else {
                        Text("No scoped styles").foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack {
                        TextField("New selector, e.g. .card-footer", text: $newRuleSelector)
                            .font(.system(.caption, design: .monospaced))
                        Button("Add rule") {
                            let selector = newRuleSelector.trimmingCharacters(in: .whitespaces)
                            guard !selector.isEmpty else { return }
                            Task {
                                await model.addStyleRule(selector: selector, media: nil, declarations: [])
                                newRuleSelector = ""
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
