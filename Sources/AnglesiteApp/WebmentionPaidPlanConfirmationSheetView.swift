import SwiftUI
import AnglesiteCore

/// Sheet shown when a deploy needs to provision the Cloudflare Queue that inbound Webmention's
/// async verification step relies on — Queues require the Workers **Paid** plan, so the app
/// asks for an explicit one-time acknowledgment before ever calling `wrangler queues create`
/// (#359). Mirrors `WorkerNameConflictSheetView`'s park-and-retry shape.
struct WebmentionPaidPlanConfirmationSheetView: View {
    let model: DeployModel
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Inbound Webmention requires the Workers Paid plan")
                    .font(.headline)
                Text("Receiving webmentions verifies each one asynchronously using a Cloudflare Queue, which isn't available on the Workers Free plan. Continuing will create a Queue on your connected Cloudflare account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Enable & retry") {
                    Task { await model.acknowledgeWebmentionPaidPlanAndRetry() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

#Preview {
    WebmentionPaidPlanConfirmationSheetView(model: DeployModel(), onCancel: {})
}
