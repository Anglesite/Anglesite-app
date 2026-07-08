import SwiftUI
import AnglesiteCore

struct SiteGraphExplorerView: View {
    @Bindable var model: SiteGraphExplorerModel
    let onOpenFile: (SiteGraphNode) -> Void

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                SiteGraphToolbar(model: model)
                Divider()
                SiteGraphCanvas(
                    nodes: model.filteredNodes,
                    edges: model.filteredEdges,
                    selectedNodeID: model.selectedNodeID,
                    onSelect: { model.selectedNodeID = $0 }
                )
            }
            .frame(minWidth: 520)

            SiteGraphInspector(
                model: model,
                onOpenFile: onOpenFile
            )
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private struct SiteGraphToolbar: View {
    @Bindable var model: SiteGraphExplorerModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Label("Site Graph", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer()
                TextField("Search graph", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(SiteGraphNodeKind.allCases) { kind in
                        Toggle(isOn: Binding(
                            get: { model.enabledKinds.contains(kind) },
                            set: { model.setKind(kind, enabled: $0) }
                        )) {
                            Label(kind.title, systemImage: kind.systemImage)
                        }
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help("Show or hide \(kind.title.lowercased())")
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(12)
    }
}

private struct SiteGraphCanvas: View {
    let nodes: [SiteGraphNode]
    let edges: [SiteGraphEdge]
    let selectedNodeID: String?
    let onSelect: (String) -> Void

    var body: some View {
        GeometryReader { proxy in
            let positions = SiteGraphLayout.positions(for: nodes, in: proxy.size)
            ZStack {
                Canvas { context, _ in
                    for edge in edges {
                        guard let start = positions[edge.sourceID], let end = positions[edge.targetID] else { continue }
                        var path = Path()
                        path.move(to: start)
                        let controlOffset = max(40, abs(end.x - start.x) * 0.35)
                        path.addCurve(
                            to: end,
                            control1: CGPoint(x: start.x + controlOffset, y: start.y),
                            control2: CGPoint(x: end.x - controlOffset, y: end.y)
                        )
                        context.stroke(
                            path,
                            with: .color(edgeColor(edge, selectedNodeID: selectedNodeID)),
                            lineWidth: highlighted(edge, selectedNodeID: selectedNodeID) ? 2 : 1
                        )
                    }
                }
                ForEach(nodes) { node in
                    if let point = positions[node.id] {
                        SiteGraphNodeButton(
                            node: node,
                            selected: node.id == selectedNodeID,
                            related: isRelated(node.id, selectedNodeID: selectedNodeID)
                        ) {
                            onSelect(node.id)
                        }
                        .position(point)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if nodes.isEmpty {
                    ContentUnavailableView("No matching graph nodes", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
        }
    }

    private func highlighted(_ edge: SiteGraphEdge, selectedNodeID: String?) -> Bool {
        guard let selectedNodeID else { return false }
        return edge.sourceID == selectedNodeID || edge.targetID == selectedNodeID
    }

    private func isRelated(_ nodeID: String, selectedNodeID: String?) -> Bool {
        guard let selectedNodeID, nodeID != selectedNodeID else { return false }
        return edges.contains {
            ($0.sourceID == selectedNodeID && $0.targetID == nodeID)
                || ($0.targetID == selectedNodeID && $0.sourceID == nodeID)
        }
    }

    private func edgeColor(_ edge: SiteGraphEdge, selectedNodeID: String?) -> Color {
        if highlighted(edge, selectedNodeID: selectedNodeID) { return .accentColor }
        switch edge.kind {
        case .imports: return .secondary.opacity(0.45)
        case .usesLayout: return .blue.opacity(0.55)
        case .referencesAsset: return .green.opacity(0.5)
        case .contains: return .orange.opacity(0.45)
        }
    }
}

private struct SiteGraphNodeButton: View {
    let node: SiteGraphNode
    let selected: Bool
    let related: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: node.kind.systemImage)
                    .font(.headline)
                Text(node.title)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 112)
                if node.referencedByCount > 0 {
                    Text("\(node.referencedByCount) refs")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(width: 132)
            .frame(minHeight: 76)
            .background(node.kind.tint.opacity(selected ? 0.24 : related ? 0.16 : 0.1))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor : node.kind.tint.opacity(0.35), lineWidth: selected ? 2 : 1)
            }
            .clipShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(node.kind.title), \(node.title)")
        .help(node.detail ?? node.title)
    }
}

private struct SiteGraphInspector: View {
    @Bindable var model: SiteGraphExplorerModel
    let onOpenFile: (SiteGraphNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let node = model.selectedNode {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Label(node.kind.title, systemImage: node.kind.systemImage)
                            .font(.headline)
                        Text(node.title)
                            .font(.title3)
                            .fontWeight(.semibold)
                            .textSelection(.enabled)
                        if let detail = node.detail {
                            Text(detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if node.filePath != nil {
                            Button("Open File", systemImage: "doc.text.magnifyingglass") {
                                onOpenFile(node)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        if let impact = model.selectedImpact {
                            Divider()
                            SiteGraphImpactSection(impact: impact, model: model)
                        }
                        Divider()
                        SiteGraphEdgeList(
                            title: "Depends On",
                            edges: model.selectedOutgoing,
                            endpoint: \.targetID,
                            model: model
                        )
                        SiteGraphEdgeList(
                            title: "Referenced By",
                            edges: model.selectedIncoming,
                            endpoint: \.sourceID,
                            model: model
                        )
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView("Select a node", systemImage: "cursorarrow.click")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}

/// Project Impact Analysis (#309): shows what editing the selected node would affect — pages
/// (transitively, through any depth of layouts/components), plus dependent layouts, components,
/// styles, containing collections, and directly referenced assets. Every row navigates to that
/// node so the blast radius can be explored in place.
private struct SiteGraphImpactSection: View {
    let impact: ImpactAnalysis.Report
    @Bindable var model: SiteGraphExplorerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Impact", systemImage: "dot.radiowaves.left.and.right")
                .font(.subheadline)
                .fontWeight(.semibold)
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
            SiteGraphImpactNodeList(
                title: "Affects \(count(impact.affectedPages.count, "Page"))",
                nodes: impact.affectedPages, model: model)
            SiteGraphImpactNodeList(
                title: "Affects \(count(impact.affectedEntries.count, "Entry", plural: "Entries"))",
                nodes: impact.affectedEntries, model: model)
            SiteGraphImpactNodeList(
                title: "Included in \(count(impact.affectedCollections.count, "Collection"))",
                nodes: impact.affectedCollections, model: model)
            SiteGraphImpactNodeList(
                title: "Used by \(count(impact.dependentLayouts.count, "Layout"))",
                nodes: impact.dependentLayouts, model: model)
            SiteGraphImpactNodeList(
                title: "Used by \(count(impact.dependentComponents.count, "Component"))",
                nodes: impact.dependentComponents, model: model)
            SiteGraphImpactNodeList(
                title: "Used by \(count(impact.dependentStyles.count, "Style"))",
                nodes: impact.dependentStyles, model: model)
            SiteGraphImpactNodeList(
                title: "References \(count(impact.referencedAssets.count, "Asset"))",
                nodes: impact.referencedAssets, model: model)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Impact analysis")
    }

    /// "This change would affect 18 pages." — the issue's headline number, pages + entries.
    /// The zero-dependents copy acknowledges a non-empty collection membership shown right
    /// below it (membership isn't a dependency, but "nothing else depends on it" directly above
    /// an "Included in 1 Collection" list reads as self-contradictory).
    private var summary: String {
        let routes = impact.affectedPages.count + impact.affectedEntries.count
        if routes > 0 {
            return "Editing this would affect \(count(routes, "page"))."
        }
        if impact.hasDependents {
            return "Editing this would affect other site files, but no rendered pages."
        }
        if !impact.affectedCollections.isEmpty {
            return "Nothing else on this site depends on it — editing it affects only this entry within its collection."
        }
        return "Nothing else on this site depends on it — editing it affects only this file."
    }

    private func count(_ n: Int, _ singular: String, plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }
}

/// A titled, clickable node list for one impact group. Hidden entirely when the group is empty —
/// unlike `SiteGraphEdgeList`, an empty impact group is noise, not information.
private struct SiteGraphImpactNodeList: View {
    let title: String
    let nodes: [SiteGraphNode]
    @Bindable var model: SiteGraphExplorerModel

    var body: some View {
        if !nodes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                ForEach(nodes) { node in
                    Button {
                        // Not a plain `selectedNodeID = …`: the impact list is computed over the
                        // full snapshot, so the node may be hidden by the toolbar kind filter or
                        // search — revealNode un-hides it so the canvas and edge lists can show
                        // the new selection (PR #545 review).
                        model.revealNode(node)
                    } label: {
                        HStack {
                            Label(node.title, systemImage: node.kind.systemImage)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if let route = node.route {
                                Text(route)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(node.detail ?? node.title)
                }
            }
        }
    }
}

private struct SiteGraphEdgeList: View {
    let title: String
    let edges: [SiteGraphEdge]
    let endpoint: KeyPath<SiteGraphEdge, String>
    @Bindable var model: SiteGraphExplorerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            if edges.isEmpty {
                Text("None")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(edges) { edge in
                    if let node = model.node(id: edge[keyPath: endpoint]) {
                        Button {
                            model.selectedNodeID = node.id
                        } label: {
                            HStack {
                                Label(node.title, systemImage: node.kind.systemImage)
                                Spacer()
                                Text(edge.kind.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private enum SiteGraphLayout {
    static func positions(for nodes: [SiteGraphNode], in size: CGSize) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        let grouped = Dictionary(grouping: nodes, by: \.kind)
        let kinds = SiteGraphNodeKind.allCases.filter { grouped[$0]?.isEmpty == false }
        let columnWidth = max(170, size.width / CGFloat(max(kinds.count, 1)))
        var output: [String: CGPoint] = [:]
        for (column, kind) in kinds.enumerated() {
            let columnNodes = (grouped[kind] ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            let rowHeight = max(96, (size.height - 60) / CGFloat(max(columnNodes.count, 1)))
            for (row, node) in columnNodes.enumerated() {
                output[node.id] = CGPoint(
                    x: min(size.width - 76, max(76, CGFloat(column) * columnWidth + columnWidth / 2)),
                    y: min(size.height - 50, max(50, CGFloat(row) * rowHeight + rowHeight / 2 + 24))
                )
            }
        }
        return output
    }
}

private extension SiteGraphNodeKind {
    var title: String {
        switch self {
        case .page: return "Pages"
        case .layout: return "Layouts"
        case .component: return "Components"
        case .collection: return "Collections"
        case .contentEntry: return "Entries"
        case .asset: return "Assets"
        case .style: return "Styles"
        }
    }

    var systemImage: String {
        switch self {
        case .page: return "doc.richtext"
        case .layout: return "rectangle.split.3x1"
        case .component: return "square.stack.3d.up"
        case .collection: return "tray.full"
        case .contentEntry: return "text.document"
        case .asset: return "photo"
        case .style: return "paintbrush"
        }
    }

    var tint: Color {
        switch self {
        case .page: return .blue
        case .layout: return .indigo
        case .component: return .teal
        case .collection: return .orange
        case .contentEntry: return .pink
        case .asset: return .green
        case .style: return .purple
        }
    }
}

private extension SiteGraphEdgeKind {
    var title: String {
        switch self {
        case .imports: return "imports"
        case .usesLayout: return "layout"
        case .referencesAsset: return "asset"
        case .contains: return "contains"
        }
    }
}
