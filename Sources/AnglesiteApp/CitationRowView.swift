import SwiftUI
import AnglesiteCore

/// Renders retrieved RAG citations as a horizontal strip of clickable chips below an assistant
/// response. Each chip shows a kind badge and the file's last path component; clicking opens
/// the file in the default editor.
struct CitationRowView: View {
    let citations: [RetrievedCitation]
    let siteDirectory: URL
    /// Resolves a citation's path to a Site Graph Explorer node and reveals it there; returns
    /// `false` when the path isn't a graph node, so the click falls back to opening the file
    /// (#314). `nil` in previews/tests that don't wire a graph explorer.
    var revealCitation: ((String) -> Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sources")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(citations) { citation in
                    CitationChip(citation: citation) {
                        Self.handleTap(
                            citation: citation, siteDirectory: siteDirectory, revealCitation: revealCitation,
                            openFile: { NSWorkspace.shared.open($0) }
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Retrieved context from \(citations.count) file\(citations.count == 1 ? "" : "s")")
    }

    /// A citation click tries `revealCitation` first (the Site Graph Explorer reveal, #314) and
    /// falls back to `openFile` only when that returns `false` or is `nil` — never both, never
    /// neither. Pulled out of the button's action closure so it's unit-testable without a SwiftUI
    /// rendering harness: `body` wires the real `NSWorkspace.shared.open` side effect, tests
    /// inject a spy.
    nonisolated static func handleTap(
        citation: RetrievedCitation,
        siteDirectory: URL,
        revealCitation: ((String) -> Bool)?,
        openFile: (URL) -> Void
    ) {
        if revealCitation?(citation.path) == true { return }
        openFile(siteDirectory.appendingPathComponent(citation.path))
    }
}

private struct CitationChip: View {
    let citation: RetrievedCitation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(citation.kind.rawValue.uppercased())
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                    .foregroundStyle(kindColor)
                Text(fileName)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(citation.path)
        .accessibilityLabel("\(citation.kind.rawValue) \(fileName)")
        .accessibilityHint("Opens \(citation.path) in the default editor")
        .accessibilityAddTraits(.isButton)
    }

    private var fileName: String {
        (citation.path as NSString).lastPathComponent
    }

    private var kindColor: Color {
        switch citation.kind {
        case .page: return .blue
        case .post: return .purple
        case .component: return .orange
        case .layout: return .teal
        case .content: return .indigo
        case .config: return .gray
        case .style: return .pink
        case .script: return .yellow
        case .other: return .secondary
        }
    }
}

/// A simple wrapping flow layout for citation chips. Uses a horizontal layout that wraps to
/// the next line when chips exceed the available width.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    struct Cache {
        var sizes: [CGSize]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let rows = computeRows(proposal: proposal, sizes: cache.sizes)
        guard !rows.isEmpty else { return .zero }
        let height = rows.reduce(CGFloat(0)) { sum, row in
            sum + row.height + (sum > 0 ? spacing : 0)
        }
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let rows = computeRows(proposal: proposal, sizes: cache.sizes)
        var y = bounds.minY
        var subviewIndex = 0
        for row in rows {
            var x = bounds.minX
            for _ in 0..<row.count {
                let size = cache.sizes[subviewIndex]
                subviews[subviewIndex].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
                subviewIndex += 1
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var count: Int
        var width: CGFloat
        var height: CGFloat
    }

    private func computeRows(proposal: ProposedViewSize, sizes: [CGSize]) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var currentRow = Row(count: 0, width: 0, height: 0)
        for size in sizes {
            let newWidth = currentRow.width + (currentRow.count > 0 ? spacing : 0) + size.width
            if currentRow.count > 0 && newWidth > maxWidth {
                rows.append(currentRow)
                currentRow = Row(count: 1, width: size.width, height: size.height)
            } else {
                currentRow.count += 1
                currentRow.width = newWidth
                currentRow.height = max(currentRow.height, size.height)
            }
        }
        if currentRow.count > 0 { rows.append(currentRow) }
        return rows
    }
}
