// Sources/AnglesiteApp/RelatedPagesPanel.swift
import SwiftUI
import AnglesiteCore

struct RelatedPagesPanel: View {
    @Bindable var model: RelatedPagesModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.suggestions.isEmpty && !model.isOrphan && model.reciprocalHints.isEmpty {
                ContentUnavailableView {
                    Label("No Suggestions", systemImage: "link")
                } description: {
                    Text("This page already links to all related content.")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !model.suggestions.isEmpty {
                            suggestionsSection
                        }
                        if !model.reciprocalHints.isEmpty {
                            reciprocalSection
                        }
                        if model.isOrphan {
                            orphanSection
                        }
                    }
                    .padding()
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Label("Related Pages", systemImage: "link.badge.plus")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggested Links")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(model.suggestions) { suggestion in
                SuggestionRow(suggestion: suggestion) {
                    model.ignore(suggestion)
                }
            }
        }
    }

    private var reciprocalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Missing Reciprocal Links")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(model.reciprocalHints) { gap in
                Label {
                    Text("Add a link back to **\(gap.targetPath)**")
                        .font(.callout)
                } icon: {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var orphanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("This page has no inbound links from other pages.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
            }
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: LinkGraph.LinkSuggestion
    let onIgnore: @MainActor () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title ?? suggestion.path)
                    .font(.callout.weight(.medium))
                Text(suggestion.route)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int(suggestion.confidence * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                let link = "[\(suggestion.title ?? suggestion.route)](\(suggestion.route))"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
            .help("Copy markdown link to clipboard")
            Button {
                onIgnore()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss suggestion")
        }
        .padding(.vertical, 4)
    }
}
