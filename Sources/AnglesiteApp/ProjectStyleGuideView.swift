import SwiftUI
import AnglesiteCore

struct ProjectStyleGuideView: View {
    @Bindable var model: ProjectStyleGuideModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if model.guide.rules.isEmpty {
                    ContentUnavailableView(
                        "No style guide yet",
                        systemImage: "text.page.badge.magnifyingglass",
                        description: Text("Open the preview so Anglesite can index pages, posts, and content collections.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.guide.rules) { rule in
                            ProjectStyleRuleRow(rule: rule)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: 820, alignment: .leading)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh Style Guide", systemImage: "arrow.clockwise")
                }
                .help("Re-read the currently indexed project conventions")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Project Style Guide", systemImage: "text.page.badge.magnifyingglass")
                .font(.title2.weight(.semibold))
            Text("\(model.guide.sourceCount) content source\(model.guide.sourceCount == 1 ? "" : "s") analyzed")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }
}

private struct ProjectStyleRuleRow: View {
    let rule: ProjectStyleGuide.Rule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                Text(rule.title)
                    .font(.headline)
                Spacer()
            }
            Text(rule.detail)
                .font(.callout)
                .textSelection(.enabled)
            if !rule.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Evidence")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(rule.evidence, id: \.self) { item in
                        Text(item)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(.rect(cornerRadius: 8))
    }
}
