import SwiftUI
import WebKit
import AnglesiteCore
import AnglesiteBridge
import AnglesiteIOS

/// Root screen of the iOS thin client: connect form until a session is configured and started,
/// then the live sandbox preview. iPad-first, but nothing here is size-class-specific yet.
struct RemoteSessionScreen: View {
    @Bindable var model: RemoteSessionModel
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text("Anglesite"))
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showsSettings = true
                        } label: {
                            Label("Session Settings", systemImage: "gearshape")
                        }
                    }
                    if case .ready = model.state {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                model.stop()
                            } label: {
                                Label("Stop", systemImage: "stop.circle")
                            }
                        }
                    }
                }
                .sheet(isPresented: $showsSettings) {
                    RemoteConnectForm(model: model)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            ContentUnavailableView {
                Label("No Site Open", systemImage: "globe")
            } description: {
                Text("Open your site in the remote sandbox to preview and edit it.")
            } actions: {
                if model.isConfigured {
                    Button("Open Site") { model.start() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Connect…") { showsSettings = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .starting(let siteID):
            VStack(spacing: 12) {
                ProgressView()
                Text("Starting \(siteID) in the sandbox…")
                    .foregroundStyle(.secondary)
            }
        case .ready(_, let url, _):
            RemoteSandboxPreview(url: url, model: model)
                .ignoresSafeArea(edges: .bottom)
        case .failed(_, let message):
            ContentUnavailableView {
                Label("Couldn't Open Site", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.start() }
                    .buttonStyle(.borderedProminent)
                Button("Session Settings…") { showsSettings = true }
            }
        }
    }
}

/// The `WKWebView` leg: composes the shared bridge configuration (script handler + edit
/// overlay user script) and injects the session-token cookie before the first request so the
/// in-container auth-proxy accepts the preview and its HMR WebSocket (#67).
private struct RemoteSandboxPreview: View {
    let url: URL
    let model: RemoteSessionModel

    var body: some View {
        let token = model.sessionToken
        let handler = AnglesiteScriptHandler(
            router: MCPApplyEditRouter(mcpClient: { [weak model] in await MainActor.run { model?.mcpClient } })
        )
        RemotePreviewWebView(
            url: url,
            makeConfiguration: {
                WebViewBridge.localDevConfiguration(handler: handler)
            },
            prepareBeforeLoad: { webView in
                guard let token, let host = url.host() else { return }
                await WebViewBridge.injectSessionToken(
                    into: webView.configuration.websiteDataStore.httpCookieStore,
                    token: token,
                    for: host
                )
            }
        )
    }
}

/// Connect form: the Worker URL + bearer token from the one-time Deploy-to-Cloudflare
/// provisioning, plus the site's git coordinates. The token field writes through to the iOS
/// Keychain (`SecretAccounts.sandboxControlToken`), never to defaults.
private struct RemoteConnectForm: View {
    @Bindable var model: RemoteSessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://anglesite-sandbox.example.workers.dev", text: $model.workerURLString)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Control Worker token", text: $model.controlToken)
                } header: {
                    Text("Cloudflare Control Worker")
                } footer: {
                    Text("From the one-time Deploy to Cloudflare setup. The token is stored in the Keychain on this device only.")
                }

                Section {
                    TextField("Site ID", text: $model.siteID)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("https://github.com/you/site.git", text: $model.gitRemoteString)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Branch", text: $model.gitRef)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Site")
                } footer: {
                    Text("The sandbox clones this repository — git stays the source of truth for your site.")
                }
            }
            .navigationTitle(Text("Remote Session"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
