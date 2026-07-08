// Sources/AnglesiteApp/ProjectStyleGuideView.swift
import SwiftUI
import AnglesiteCore

/// Sheet showing the site's learned `ProjectConventions`, sectioned by category, with an
/// edit/override affordance per learnable field. Frontmatter is read-only (ground truth from
/// `content.config.ts`, not inference — see `FrontmatterSchemaReader`).
struct ProjectStyleGuideView: View {
    let model: ProjectConventionsModel
    let siteName: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let conventions = model.conventions {
                    List {
                        writingSection(conventions)
                        imagesSection(conventions)
                        componentsSection(conventions)
                        namingSection(conventions)
                        seoSection(conventions)
                        frontmatterSection(conventions)
                    }
                } else {
                    ProgressView("Learning \(siteName)’s conventions…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Project Style Guide")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Rescan Now") {
                        Task { await model.rescan() }
                    }
                    .disabled(model.isLearning)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    // MARK: Sections

    @ViewBuilder
    private func writingSection(_ conventions: ProjectConventions) -> some View {
        Section("Writing") {
            learnedRow(
                "Heading style",
                display: conventions.writing.headingCapitalization.value.rawValue,
                learned: conventions.writing.headingCapitalization,
                onClear: { Task { await model.clearOverride(.headingCapitalization) } }
            )
            learnedRow(
                "Tone",
                display: conventions.writing.toneDescriptors.value.isEmpty
                    ? "Not learned yet" : conventions.writing.toneDescriptors.value.joined(separator: ", "),
                learned: conventions.writing.toneDescriptors,
                onClear: { Task { await model.clearOverride(.toneDescriptors) } }
            )
            learnedRow(
                "Brand terms",
                display: conventions.writing.brandTerms.value.isEmpty
                    ? "Not learned yet" : conventions.writing.brandTerms.value.joined(separator: ", "),
                learned: conventions.writing.brandTerms,
                onClear: { Task { await model.clearOverride(.brandTerms) } }
            )
        }
    }

    @ViewBuilder
    private func imagesSection(_ conventions: ProjectConventions) -> some View {
        Section("Images") {
            learnedRow(
                "Average alt text length",
                display: "\(conventions.images.altTextAverageLength.value) characters",
                learned: conventions.images.altTextAverageLength,
                onClear: { Task { await model.clearOverride(.altTextAverageLength) } }
            )
            learnedRow(
                "Ends with punctuation",
                display: conventions.images.altTextEndsWithPunctuation.value ? "Yes" : "No",
                learned: conventions.images.altTextEndsWithPunctuation,
                onClear: { Task { await model.clearOverride(.altTextEndsWithPunctuation) } }
            )
        }
    }

    @ViewBuilder
    private func componentsSection(_ conventions: ProjectConventions) -> some View {
        Section("Components") {
            if conventions.components.usageCounts.value.isEmpty {
                Text("No component usage learned yet.").foregroundStyle(.secondary)
            } else {
                ForEach(conventions.components.usageCounts.value.sorted(by: { $0.value > $1.value }), id: \.key) { name, count in
                    LabeledContent(name) { Text("\(count)") }
                }
            }
        }
    }

    @ViewBuilder
    private func namingSection(_ conventions: ProjectConventions) -> some View {
        Section("Naming") {
            learnedRow(
                "Slug style",
                display: conventions.naming.slugStyle.value.rawValue,
                learned: conventions.naming.slugStyle,
                onClear: { Task { await model.clearOverride(.slugStyle) } }
            )
        }
    }

    @ViewBuilder
    private func seoSection(_ conventions: ProjectConventions) -> some View {
        Section("SEO") {
            learnedRow(
                "Average meta description length",
                display: "\(conventions.seo.metaDescriptionAverageLength.value) characters",
                learned: conventions.seo.metaDescriptionAverageLength,
                onClear: { Task { await model.clearOverride(.metaDescriptionAverageLength) } }
            )
        }
    }

    @ViewBuilder
    private func frontmatterSection(_ conventions: ProjectConventions) -> some View {
        Section("Frontmatter (read from content.config.ts)") {
            if conventions.frontmatter.collections.isEmpty {
                Text("No content collections found.").foregroundStyle(.secondary)
            } else {
                ForEach(conventions.frontmatter.collections.keys.sorted(), id: \.self) { name in
                    LabeledContent(name) {
                        Text((conventions.frontmatter.collections[name] ?? []).joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Row helper

    @ViewBuilder
    private func learnedRow<Value>(
        _ label: String, display: String, learned: Learned<Value>, onClear: @escaping () -> Void
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(display)
                if learned.isOverridden {
                    Text("edited").font(.caption2).foregroundStyle(.secondary)
                    Button("Revert", action: onClear).font(.caption2)
                } else if let sampleSize = learned.sampleSize, sampleSize > 0, sampleSize < 3 {
                    Text("low confidence").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
