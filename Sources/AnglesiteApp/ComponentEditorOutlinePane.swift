import SwiftUI
import AnglesiteCore

/// Left pane: the component's structure outline plus the drag-and-drop palette (design spec
/// §4.1). Selection binds directly to `model.selectedNodeID`; drag/drop hit-testing decisions
/// (`dropZone`/parent+sibling resolution) and the resulting `insertNode`/`moveNode` dispatch live
/// on `ComponentEditorModel` (`performMove`/`performInsert`, #824) — this view only supplies the
/// SwiftUI-required synchronous guard (same file, not a self-drop) before handing off to the
/// model via `Task`.
struct ComponentEditorOutlinePane: View {
    @Bindable var model: ComponentEditorModel
    let onExtract: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(model.outlineRows, selection: $model.selectedNodeID) { row in
                outlineRow(row: row)
                    .tag(row.node.id)
            }
            .listStyle(.sidebar)
            Divider()
            paletteView
                .frame(height: 160)
        }
    }

    private func outlineRow(row: ComponentOutline.Row) -> some View {
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
                Task { await model.performMove(draggedNodeID: dragItem.nodeID, targetRow: row, location: location) }
                return true
            case .insert(let payload):
                Task { await model.performInsert(payload: payload.kind, targetRow: row, location: location) }
                return true
            }
        }
        .onTapGesture(count: 2) {
            guard row.isSealed else { return }
            model.openReferencedComponent(tag: row.node.tag)
        }
        .contextMenu {
            if model.canExtractComponent(row) {
                Button("Extract into Component…") {
                    onExtract(row.node.id)
                }
            }
        }
    }

    private var paletteView: some View {
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
