import SwiftUI
import AnglesiteQuickLookSupport

/// Rendered inside `PreviewViewController`'s hosting controller. `summary == nil` covers every
/// "not a readable Anglesite site" case (missing/corrupt marker) — Quick Look has no good
/// error-surfacing UI of its own, so this in-view fallback is preferable to throwing.
struct PreviewContentView: View {
    let summary: PackagePreviewSummary?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        if let summary {
            VStack(alignment: .leading, spacing: 12) {
                header(for: summary)
                Divider()
                stats(for: summary)
                Spacer()
            }
            .padding(20)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "questionmark.folder")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Not a readable Anglesite site")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func header(for summary: PackagePreviewSummary) -> some View {
        HStack(spacing: 12) {
            if let thumbnailURL = summary.cachedThumbnailURL, let image = NSImage(contentsOf: thumbnailURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 32))
                    .frame(width: 64, height: 64)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.displayName)
                    .font(.title2)
                    .bold()
                Text("Created \(Self.dateFormatter.string(from: summary.createdDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func stats(for summary: PackagePreviewSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(summary.pageCount) page\(summary.pageCount == 1 ? "" : "s")")
            ForEach(summary.collectionCounts, id: \.name) { collection in
                Text("\(collection.count) \(collection.name)")
            }
            if let lastModified = summary.sourceLastModified {
                Text("Last modified \(Self.dateFormatter.string(from: lastModified))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.body)
    }
}
