import SwiftUI
import AnglesiteCore

/// First-deploy modal: ask the user to paste their Cloudflare API token, store it in the
/// Keychain, and let the parked deploy proceed. Surfaced by `DeployModel` when both the env var
/// and the Keychain are empty at the moment the user clicks Deploy.
///
/// The view is intentionally narrow — it only captures the token. Long-term management
/// (replacing, clearing) happens in Settings → Advanced → Credentials. Surfacing the same
/// `KeychainStore` slot here means a token saved from either entry point is immediately usable
/// by `wrangler deploy`.
struct CloudflareTokenPromptView: View {
    let model: DeployModel
    let onCancel: () -> Void

    @State private var token: String = ""
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cloudflare API token required")
                    .font(.headline)
                Text("Anglesite needs an API token to run `wrangler deploy`. Paste one below — it'll be stored in your Mac's Keychain and re-used for future deploys.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SecureField("API token", text: $token, prompt: Text("paste token"))
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(save)

            Link(
                "Create an API token at Cloudflare →",
                destination: URL(string: "https://dash.cloudflare.com/profile/api-tokens")!
            )
            .font(.footnote)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save & deploy") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { fieldFocused = true }
    }

    private func save() {
        if let message = model.saveTokenAndRetry(token) {
            errorMessage = message
        }
    }
}

#Preview {
    CloudflareTokenPromptView(model: DeployModel(), onCancel: {})
}
