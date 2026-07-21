import Foundation
import Observation
import AnglesiteCore

/// Drives one remote sandbox session for the iOS thin client (#71).
///
/// Owns the configuration (Control Worker URL + bearer token + the site's git coordinates),
/// the `RemoteSandboxSiteRuntime`, and a mirror of its state stream for SwiftUI. The bearer
/// token lives in the iOS Keychain (`KeychainStore`, `kSecAttrAccessibleAfterFirstUnlock-
/// ThisDeviceOnly` — same accessibility class as macOS); everything else is plain defaults.
@MainActor
@Observable
public final class RemoteSessionModel {
    // MARK: Configuration (persisted)

    /// Base URL of the user's deployed Sandbox Control Worker (design 2026-06-23 §"Provision").
    public var workerURLString: String {
        didSet { defaults.set(workerURLString, forKey: Self.workerURLKey) }
    }

    /// HTTPS clone URL of the site's `Source/` repo — the sandbox hydrates from git (#72).
    public var gitRemoteString: String {
        didSet { defaults.set(gitRemoteString, forKey: Self.gitRemoteKey) }
    }

    public var gitRef: String {
        didSet { defaults.set(gitRef, forKey: Self.gitRefKey) }
    }

    /// Stable per-user site identifier the Control Worker keys its sandbox Durable Object on.
    public var siteID: String {
        didSet { defaults.set(siteID, forKey: Self.siteIDKey) }
    }

    /// The Control Worker bearer token, Keychain-backed. Never logged, never in defaults.
    public var controlToken: String {
        didSet {
            // `SecretStore.write("")` deletes the entry, so clearing the field round-trips.
            try? secretStore.write(controlToken, account: SecretAccounts.sandboxControlToken)
        }
    }

    // MARK: Session

    public private(set) var state: SiteRuntimeState = .idle
    /// The session token for the *current* start attempt — the preview screen injects it as the
    /// auth-proxy cookie before the first `WKWebView` request (design 2026-06-23 §"Start session").
    public private(set) var sessionToken: SessionToken?
    public private(set) var mcpClient: MCPClient?

    private var runtime: RemoteSandboxSiteRuntime?
    private var observationTask: Task<Void, Never>?

    private let defaults: UserDefaults
    private let secretStore: any SecretStore

    private static let workerURLKey = "remoteSession.workerURL"
    private static let gitRemoteKey = "remoteSession.gitRemote"
    private static let gitRefKey = "remoteSession.gitRef"
    private static let siteIDKey = "remoteSession.siteID"

    public init(
        defaults: UserDefaults = .standard,
        secretStore: (any SecretStore)? = nil
    ) {
        self.defaults = defaults
        let store: any SecretStore = secretStore ?? KeychainStore()
        self.secretStore = store
        self.workerURLString = defaults.string(forKey: Self.workerURLKey) ?? ""
        self.gitRemoteString = defaults.string(forKey: Self.gitRemoteKey) ?? ""
        self.gitRef = defaults.string(forKey: Self.gitRefKey) ?? "main"
        self.siteID = defaults.string(forKey: Self.siteIDKey) ?? ""
        self.controlToken = (try? store.read(account: SecretAccounts.sandboxControlToken) ?? "") ?? ""
    }

    /// Everything the Control Worker needs before a session can start. The connect form gates
    /// its "Open Site" button on this; `start()` also refuses (routing back to the form) so a
    /// stale deep-link can't reach the Worker unauthenticated.
    public var isConfigured: Bool {
        workerURL != nil && gitRemote != nil && !controlToken.isEmpty && !siteID.isEmpty
    }

    public var workerURL: URL? {
        guard let url = URL(string: workerURLString), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    public var gitRemote: URL? {
        guard let url = URL(string: gitRemoteString), url.scheme != nil else { return nil }
        return url
    }

    /// Boot (or reboot) the remote session. Safe to call repeatedly — the runtime tears down
    /// any previous session first.
    public func start() {
        guard isConfigured, let workerURL, let gitRemote else {
            state = .failed(siteID: siteID, message: String(localized: "Connect your Cloudflare Worker first."))
            return
        }
        observationTask?.cancel()

        let token = SessionToken.mint()
        sessionToken = token
        let control = HTTPSandboxControlClient(workerBaseURL: workerURL, apiToken: controlToken)
        // iOS never spawns: the default supervisor backend is `UnavailableProcessBackend`, and
        // this client only ever uses the HTTP transport (`connect(httpEndpoint:)`).
        let client = MCPClient(supervisor: ProcessSupervisor())
        mcpClient = client
        let runtime = RemoteSandboxSiteRuntime(
            gitRemote: gitRemote,
            gitRef: gitRef,
            control: control,
            mcpClient: client,
            mintToken: { token }
        )
        self.runtime = runtime

        observationTask = Task { [weak self] in
            let stream = await runtime.observe()
            for await next in stream {
                guard let self, !Task.isCancelled else { return }
                self.state = next
            }
        }

        let id = siteID
        Task {
            // `siteDirectory` is unused on the remote path (no local files on iOS).
            await runtime.start(siteID: id, siteDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        }
    }

    public func stop() {
        guard let runtime else { return }
        self.runtime = nil
        sessionToken = nil
        mcpClient = nil
        observationTask?.cancel()
        observationTask = nil
        state = .idle
        Task { await runtime.stop() }
    }
}
