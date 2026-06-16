import SwiftUI
import AnglesiteCore

/// First-deploy modal: guide the user through creating a Cloudflare API token, verify it against
/// Cloudflare, store it in the Keychain, and let the parked deploy proceed. Surfaced by
/// `DeployModel` when both the env var and the Keychain are empty at the moment the user clicks
/// Deploy.
///
/// The hard part for newcomers isn't pasting — it's knowing *which* token to make. So step 1 links
/// to a pre-filled Cloudflare token form that reproduces the built-in "Edit Cloudflare Workers"
/// template (the exact permissions `wrangler deploy` needs), and the numbered steps name that
/// template by hand in case the (undocumented) pre-fill ever stops working. The token isn't trusted
/// on faith: `DeployModel.verifyAndSaveToken` runs `wrangler whoami` before persisting, so a bad
/// token is caught here instead of failing later inside the deploy.
///
/// The view is intentionally narrow — it only onboards the token. Long-term management (replacing,
/// clearing) happens in Settings → Advanced → Credentials, which shares the same `KeychainStore`
/// slot, so a token saved from either entry point is immediately usable by `wrangler deploy`.
struct CloudflareTokenPromptView: View {
    let model: DeployModel
    let onCancel: () -> Void

    @State private var token: String = ""
    @FocusState private var fieldFocused: Bool

    /// Cloudflare's dashboard accepts undocumented query params that pre-fill the token-creation
    /// form. These five permission groups reproduce the built-in "Edit Cloudflare Workers" template
    /// — everything a Workers + Static Assets `wrangler deploy` needs. Verified against the live
    /// dashboard on 2026-06-16: all five rows + the name pre-fill. If Cloudflare ever changes the
    /// param schema, the link still lands on the token page and the on-screen steps name the
    /// template to pick by hand, so the flow degrades rather than breaks.
    private static let createTokenURL: URL = {
        let permissions = """
        [{"key":"workers_routes","type":"edit"},\
        {"key":"workers_scripts","type":"edit"},\
        {"key":"workers_kv_storage","type":"edit"},\
        {"key":"workers_tail","type":"read"},\
        {"key":"workers_r2","type":"edit"}]
        """
        var components = URLComponents(string: "https://dash.cloudflare.com/profile/api-tokens")!
        components.queryItems = [
            URLQueryItem(name: "name", value: "Anglesite Deploy"),
            URLQueryItem(name: "accountId", value: "*"),
            URLQueryItem(name: "zoneId", value: "all"),
            URLQueryItem(name: "permissionGroupKeys", value: permissions)
        ]
        return components.url!
    }()

    private var isChecking: Bool {
        if case .checking = model.tokenVerification { return true }
        if case .connected = model.tokenVerification { return true }
        return false
    }

    private var canSubmit: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isChecking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect to Cloudflare")
                    .font(.headline)
                Text("Deploying needs a one-time API token. It takes about a minute.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                step(1) {
                    Link(destination: Self.createTokenURL) {
                        Label("Open Cloudflare API tokens", systemImage: "arrow.up.forward.app")
                    }
                }
                step(2) {
                    Text("The “Edit Cloudflare Workers” permissions should already be selected (if not, pick that template). Click **Continue to summary**.")
                }
                step(3) {
                    Text("Click **Create Token**, then copy it and paste it below.")
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            SecureField("API token", text: $token, prompt: Text("paste token"))
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .disabled(isChecking)
                .onSubmit { submit() }

            status
                .frame(minHeight: 16, alignment: .leading)

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect & deploy") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { fieldFocused = true }
    }

    /// A numbered step: a circled index followed by its content.
    @ViewBuilder
    private func step(_ index: Int, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(index)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            content()
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.tokenVerification {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking token…").foregroundStyle(.secondary)
            }
            .font(.footnote)
        case .connected(let accountName):
            Label(
                accountName.map { "Connected to \($0)" } ?? "Token verified",
                systemImage: "checkmark.circle.fill"
            )
            .font(.footnote)
            .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        Task { await model.verifyAndSaveToken(token) }
    }
}

#Preview {
    CloudflareTokenPromptView(model: DeployModel(), onCancel: {})
}
