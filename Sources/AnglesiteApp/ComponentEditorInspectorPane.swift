import SwiftUI
import WebKit
import AnglesiteCore

/// Right pane: the selected node's attributes, the Props form, the Code pane
/// (`ComponentEditorCodePane`), conflict/write-error banners, the Styles panel (grouped-by-media
/// declaration editing), and Computed values.
///
/// The draft dictionaries backing every editable field here (selector/property/value/attribute
/// drafts, the props/code drafts), the dirty checks that gate the Save buttons, and the
/// `ColorPicker` commit debounce all live on `ComponentEditorModel` (#824) — this view only reads
/// them through the model's `…Draft(for:)` accessors, writes keystrokes back through the matching
/// `set…Draft` calls, and triggers a commit on submit/blur/explicit Save.
///
/// `webView` is read-only here (threaded down from `ComponentEditorCanvasPane` via the parent
/// view) — used only to push a live scrub preview while a `ColorPicker` drags; the model has no
/// webview handle of its own.
struct ComponentEditorInspectorPane: View {
    @Bindable var model: ComponentEditorModel
    var webView: WKWebView?
    @Binding var codeZone: ComponentEditorModel.CodeZone
    @Binding var newRuleSelector: String
    @Binding var newRuleMedia: String
    @Binding var collapsedMediaKeys: Set<String>
    @Binding var newAttrName: String
    @Binding var newAttrValue: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let node = model.selectedNode {
                    selectionGroup(node: node)
                }
                propsForm
                ComponentEditorCodePane(model: model, codeZone: $codeZone)
                if model.conflict {
                    conflictBanner
                }
                if let writeError = model.writeError {
                    writeErrorBanner(message: writeError)
                }
                stylesGroup
                computedGroup
            }
            .padding(10)
        }
    }

    // MARK: - Selection / attributes

    private func selectionGroup(node: ComponentModel.Node) -> some View {
        GroupBox("Selection") {
            LabeledContent("Kind", value: node.kind.rawValue)
            if let tag = node.tag { LabeledContent("Tag", value: tag) }
            ForEach(node.attrs, id: \.name) { attr in
                HStack(spacing: 4) {
                    Text(attr.name).font(.system(.caption, design: .monospaced)).frame(width: 90, alignment: .leading)
                    TextField("value", text: attrValueBinding(node: node, name: attr.name))
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.plain)
                        .onSubmit { model.commitAttr(node: node, name: attr.name) }
                    Button(role: .destructive) {
                        model.removeAttr(node: node, name: attr.name)
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

    private func attrValueBinding(node: ComponentModel.Node, name: String) -> Binding<String> {
        Binding(
            get: { model.attrValueDraft(node: node, name: name) },
            set: { model.setAttrValueDraft($0, node: node, name: name) }
        )
    }

    // MARK: - Props form

    /// Structured Props form (design spec §4.3): the component's `Props` interface as
    /// name/type/optional/default rows, independent of outline selection — props belong to the
    /// component as a whole, not to any one template node. Edits accumulate in
    /// `model.propsDraft` and commit together via "Save Props".
    private var propsForm: some View {
        GroupBox("Props") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach($model.propsDraft) { $prop in
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
                            model.propsDraft.removeAll { $0.id == prop.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    Button("Add Prop") {
                        model.propsDraft.append(ComponentEditorModel.PropDraft(name: "", type: "string", optional: false, defaultValue: ""))
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    Spacer()
                    Button("Save Props") {
                        Task { await model.savePropsDraft() }
                    }
                    .disabled(!model.propsDraftDirty)
                }
            }
        }
    }

    // MARK: - Banners

    /// "This component changed outside Anglesite" banner — the edit that triggered a stale-write
    /// refusal was never applied; `ComponentEditorModel.applyComponentStyleEdit` already reloaded
    /// the latest version, so this just informs the user why their change didn't stick.
    private var conflictBanner: some View {
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
    /// staleness (invalid value, drifted `ruleSpan`, transient MCP error). Scoped to this pane so
    /// a routine write failure never takes over the whole editor (see `ComponentEditorModel
    /// .writeError`'s doc comment).
    private func writeErrorBanner(message: String) -> some View {
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

    // MARK: - Styles panel

    private var stylesGroup: some View {
        GroupBox("Styles") {
            if let styles = model.model?.styles, !styles.isEmpty {
                let groups = ComponentStyleGrouping.groups(from: styles)
                ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
                    DisclosureGroup(isExpanded: mediaExpandedBinding(for: group.media)) {
                        ForEach(Array(group.rules.enumerated()), id: \.element.index) { position, indexed in
                            ruleRow(ruleIndex: indexed.index, rule: indexed.rule)
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

    /// One rule's editable selector + declaration rows, grouped by media above.
    @ViewBuilder
    private func ruleRow(ruleIndex: Int, rule: ComponentModel.StyleRule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("selector", text: selectorBinding(for: rule))
                .font(.system(.caption, design: .monospaced))
                .textFieldStyle(.plain)
                .bold()
                .onSubmit { model.commitSelector(rule: rule) }
            ForEach(rule.declarations, id: \.property) { decl in
                HStack(spacing: 4) {
                    TextField("property", text: propertyBinding(for: decl))
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.plain)
                        .frame(width: 110)
                        .onSubmit { Task { await model.commitDeclaration(ruleIndex: ruleIndex, rule: rule, decl: decl) } }
                    Text(":")
                    declarationValueField(ruleIndex: ruleIndex, rule: rule, decl: decl)
                    Button(role: .destructive) {
                        model.removeDeclaration(rule: rule, decl: decl)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Add declaration") {
                let newProperty = "new-property-\(UUID().uuidString.prefix(8))"
                Task { await model.setStyleProperty(ruleSpan: [rule.span.start, rule.span.end], property: newProperty, value: "") }
            }
            .font(.caption2)
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func selectorBinding(for rule: ComponentModel.StyleRule) -> Binding<String> {
        Binding(
            get: { model.selectorDraft(for: rule) },
            set: { model.setSelectorDraft($0, for: rule) }
        )
    }

    private func propertyBinding(for decl: ComponentModel.Declaration) -> Binding<String> {
        Binding(
            get: { model.propertyDraft(for: decl) },
            set: { model.setPropertyDraft($0, for: decl) }
        )
    }

    @ViewBuilder
    private func declarationValueField(
        ruleIndex: Int,
        rule: ComponentModel.StyleRule,
        decl: ComponentModel.Declaration
    ) -> some View {
        let valueBinding = Binding(
            get: { model.valueDraft(for: decl) },
            set: { model.setValueDraft($0, for: decl) }
        )
        HStack(spacing: 4) {
            TextField("value", text: valueBinding)
                .font(.system(.caption, design: .monospaced))
                .textFieldStyle(.plain)
                .onSubmit { Task { await model.commitDeclaration(ruleIndex: ruleIndex, rule: rule, decl: decl) } }
            if CSSColor.colorProperties.contains(decl.property),
               let color = CSSColor.parse(valueBinding.wrappedValue) {
                ColorPicker("", selection: Binding(
                    get: { color },
                    set: { newColor in
                        let formatted = CSSColor.format(newColor)
                        model.setValueDraft(formatted, for: decl)
                        webView?.evaluateJavaScript(
                            "window.anglesiteCanvas?.scrub?.(\(jsStringLiteral(rule.selector)), \(jsStringLiteral(decl.property)), \(jsStringLiteral(formatted)))"
                        )
                        model.debounceColorCommit(ruleIndex: ruleIndex, rule: rule, decl: decl) {
                            Task { _ = try? await webView?.evaluateJavaScript("window.anglesiteCanvas?.clearScrub?.()") }
                        }
                    }
                ))
                .labelsHidden()
            }
        }
    }

    /// Escapes a Swift string into a double-quoted JS string literal for
    /// interpolation into `evaluateJavaScript` call sites.
    private func jsStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Computed

    private var computedGroup: some View {
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
}
