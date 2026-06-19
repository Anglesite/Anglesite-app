import SwiftUI

/// Determinate dev-server startup indicator: a title line, a linear progress bar driven by
/// `StartupProgressModel.fraction`, and the current curated phase message beneath it. Replaces the
/// indeterminate spinner the preview pane used to show while `astro dev` booted.
struct StartupProgressView: View {
    let title: String
    let model: StartupProgressModel

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            ProgressView(value: model.fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 320)
            // Fixed height so the layout doesn't jump as messages change; empty between phases.
            Text(model.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(height: 18)
                .animation(.easeInOut(duration: 0.2), value: model.message)
        }
        .frame(maxWidth: 360)
        .animation(.easeInOut(duration: 0.2), value: model.fraction)
    }
}
