import SwiftUI
import AnglesiteCore

/// SwiftUI-facing wrapper around `DeployCommand`. Drives one deploy at a time and exposes the
/// live log stream, the terminal `Phase`, and the two presentation flags the views consume.
///
/// Subscribes to `LogCenter` for the deploy's lifetime, filtering by source so the drawer only
/// shows wrangler / build output (not unrelated Astro or MCP traffic). Subscription is dropped
/// once the deploy resolves — the drawer keeps the captured `logLines` so the user can read and
/// copy them after dismissal becomes available.
@MainActor
@Observable
final class DeployModel {
    enum Phase: Equatable {
        case idle
        case running(siteID: String, since: Date)
        case succeeded(url: URL, duration: TimeInterval)
        case failed(reason: String, exitCode: Int32?)
        case blocked(failures: [PreDeployCheck.ScanFailure], warnings: [PreDeployCheck.ScanWarning])
    }

    private(set) var phase: Phase = .idle
    /// Captured deploy + build log lines for the current/most-recent run.
    private(set) var logLines: [LogCenter.LogLine] = []
    /// The latest milestone label from the running deploy (drives a status line above the log).
    private(set) var currentMilestone: String?
    /// On-device summary of the most recent *failed* deploy, or nil if none/unavailable.
    private(set) var failureSummary: DeployFailureSummary?
    /// True while the failure summary is being generated (drives a spinner in the drawer).
    private(set) var summarizing: Bool = false

    /// Bound to a custom slide-up drawer in `SiteWindow`. The view sets this back to false
    /// when the user clicks "Dismiss" (we never auto-close — users want to read the URL).
    var drawerPresented: Bool = false
    /// Bound to a `.sheet` in `SiteWindow` for the `.blocked` outcome. The sheet has no
    /// override button — per CLAUDE.md, the app cannot bypass plugin security hooks.
    var blockedPresented: Bool = false
    /// Bound to a `.sheet` in `SiteWindow` for the first-deploy "paste your Cloudflare token"
    /// flow. Set when `deploy(...)` is invoked without a token in either the env or the
    /// Keychain; cleared when the user saves a token (which then retries the deploy) or cancels.
    var tokenPromptPresented: Bool = false

    /// Progress of verifying a pasted token, consumed by `CloudflareTokenPromptView`'s status line
    /// and button-enabled logic. A token is only written to the Keychain once verification reaches
    /// `.connected`; a `.failed` state keeps the sheet open and leaves the Keychain untouched.
    enum TokenVerification: Equatable {
        case idle
        case checking
        case connected(accountName: String?)
        case failed(message: String)
    }
    private(set) var tokenVerification: TokenVerification = .idle

    /// Fires every time the deploy pipeline's preflight step resolves, with the
    /// `PreDeployCheck.Outcome` that was used to decide whether to continue.
    /// `SiteWindow` wires this to `HealthModel.ingestDeployOutcome` so the health
    /// badge updates whenever a deploy runs — including the .passed and warnings-only
    /// cases that don't surface through `phase`.
    var onScanComplete: ((PreDeployCheck.Outcome) -> Void)?

    /// Fires on every phase change — start and terminal alike — with the site id of the run the
    /// transition belongs to. The id is delivered per-run (not captured at wiring time) so a
    /// window replayed onto a different site can't mis-attribute a still-in-flight deploy's
    /// outcome. `SiteWindowModel` wires this to the completion notifier and Dock progress
    /// (#526); the model stays UserNotifications- and AppKit-free.
    @ObservationIgnored var onPhaseTransition: ((_ siteID: String, _ phase: Phase) -> Void)?
    /// Fires (on the main actor) for each structured milestone of the identified run, after
    /// `currentMilestone` updates. Drives the determinate Dock-tile progress bar (#526).
    @ObservationIgnored var onMilestone: ((_ siteID: String, _ progress: OperationProgress) -> Void)?

    private let command: DeployCommand
    private let webmentionCommand: WebmentionSendCommand
    private let posseCommand: POSSESyndicationCommand
    private let logCenter: LogCenter
    private let keychain: KeychainStore
    private let onboarding: TokenOnboarding
    private let summarizer: any DeployFailureSummarizing
    /// Bumped at the start of every `runDeploy`. The async failure-summarization captures the
    /// value at dispatch and only writes its result back if it still matches — so a summary from
    /// a superseded deploy can't stomp the current deploy's state, even though
    /// `generateStructured` doesn't honour cooperative cancellation.
    private var summarizationGeneration: UInt = 0
    private var inFlight: Task<Void, Never>?
    private let suddenTerminationController: SuddenTerminationController
    private let tokenAvailabilityOverride: (() -> Bool)?
    /// Site to retry once the user pastes a token. `nil` outside the prompt flow.
    /// Carries the container control (if any) so the parked-then-retried deploy
    /// uses the same executor as the original dispatch.
    private var pendingDeploy: (
        siteID: String,
        siteDirectory: URL,
        configDirectory: URL,
        currentRoutes: [String],
        containerControl: (siteID: String, control: any LocalContainerControl)?
    )?

    init(
        command: DeployCommand = DeployCommand(),
        webmentionCommand: WebmentionSendCommand = WebmentionSendCommand(),
        posseCommand: POSSESyndicationCommand = POSSESyndicationCommand(),
        logCenter: LogCenter = .shared,
        keychain: KeychainStore = KeychainStore(),
        verifier: TokenVerifying = CloudflareAPITokenVerifier(),
        summarizer: any DeployFailureSummarizing = DeploySummarizerFactory.makeDefault(),
        suddenTerminationController: SuddenTerminationController = .shared,
        tokenAvailabilityOverride: (() -> Bool)? = nil
    ) {
        self.command = command
        self.webmentionCommand = webmentionCommand
        self.posseCommand = posseCommand
        self.logCenter = logCenter
        self.keychain = keychain
        self.onboarding = TokenOnboarding(verifier: verifier)
        self.summarizer = summarizer
        self.suddenTerminationController = suddenTerminationController
        self.tokenAvailabilityOverride = tokenAvailabilityOverride
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// Renders the captured log lines as plain text for the "Copy log" affordance on failure.
    var logText: String {
        logLines.map(\.text).joined(separator: "\n")
    }

    /// Kicks off a deploy. No-op if one is already running.
    ///
    /// When `containerControl` is non-nil the deploy runs inside the already-started container via
    /// `ContainerDeployExecutor`; otherwise the default executor reports that the container runtime
    /// is required. The container control is threaded through the pending-deploy flow so a
    /// token-prompt retry uses the same executor as the original dispatch.
    ///
    /// First checks whether a Cloudflare token is available (env > Keychain). If neither has one,
    /// the token-prompt sheet is presented and the deploy is parked until the user pastes and
    /// verifies a token via `verifyAndSaveToken(_:)` — at which point the parked site is dispatched
    /// without the user having to click Deploy again.
    func deploy(
        siteID: String,
        siteDirectory: URL,
        configDirectory: URL,
        currentRoutes: [String],
        containerControl: (siteID: String, control: any LocalContainerControl)? = nil
    ) {
        guard !isRunning else { return }
        if !hasUsableToken() {
            pendingDeploy = (siteID, siteDirectory, configDirectory, currentRoutes, containerControl)
            tokenVerification = .idle
            tokenPromptPresented = true
            return
        }
        // Flip `phase` synchronously, before scheduling the Task, so a second `deploy()` call
        // on the same actor hop (e.g. a rapid re-invocation before this Task starts running)
        // sees `isRunning == true` and bails via the guard above instead of racing runDeploy.
        phase = .running(siteID: siteID, since: Date())
        let suddenTerminationLease = suddenTerminationController.acquire()
        inFlight = Task { @MainActor [weak self, suddenTerminationLease] in
            await self?.runDeploy(
                siteID: siteID, siteDirectory: siteDirectory,
                configDirectory: configDirectory, currentRoutes: currentRoutes,
                containerControl: containerControl,
                suddenTerminationLease: suddenTerminationLease)
        }
    }

    /// Called by the token-prompt sheet's "Connect & deploy" button. Verifies the token against
    /// Cloudflare (via `wrangler whoami`) *before* persisting it — so a bad token is caught here
    /// rather than failing later inside the deploy, and never reaches the Keychain. On success the
    /// token is stored, the connected account is surfaced briefly, and the parked deploy is
    /// dispatched. On failure the sheet stays open with a specific message.
    func verifyAndSaveToken(_ token: String) async {
        guard let pending = pendingDeploy else {
            // The prompt is only shown with a parked deploy; guard defensively.
            tokenVerification = .failed(message: "No deploy is waiting — close this and click Deploy again.")
            return
        }

        tokenVerification = .checking
        // `TokenOnboarding` owns the verify → persist → flash → re-check-cancel ordering; this method
        // just maps its outcome onto observable state and the parked deploy. `isCancelled` covers
        // both the user hitting Cancel (which clears `tokenPromptPresented` via `cancelTokenPrompt`)
        // and the view tearing down (which cancels this Task).
        let outcome = await onboarding.run(
            token: token,
            siteDirectory: pending.siteDirectory,
            persist: { try keychain.writeCloudflareToken($0) },
            onConnected: { tokenVerification = .connected(accountName: $0.name) },
            delay: { try? await Task.sleep(for: .milliseconds(700)) },
            isCancelled: { Task.isCancelled || !tokenPromptPresented }
        )

        switch outcome {
        case .proceed:
            pendingDeploy = nil
            tokenPromptPresented = false
            tokenVerification = .idle
            deploy(
                siteID: pending.siteID, siteDirectory: pending.siteDirectory,
                configDirectory: pending.configDirectory, currentRoutes: pending.currentRoutes,
                containerControl: pending.containerControl)
        case .stay(let message):
            tokenVerification = .failed(message: message)
        case .abort:
            // The user cancelled mid-flow; `cancelTokenPrompt` already cleared the parked deploy.
            tokenVerification = .idle
        }
    }

    func cancelTokenPrompt() {
        pendingDeploy = nil
        tokenPromptPresented = false
        tokenVerification = .idle
    }

    func dismissDrawer() {
        drawerPresented = false
    }

    func dismissBlocked() {
        blockedPresented = false
    }

    /// True if either the env var or the Keychain currently holds a non-empty Cloudflare token.
    /// Keychain errors are treated as "no token" — the user can recover by pasting fresh.
    private func hasUsableToken() -> Bool {
        if let tokenAvailabilityOverride {
            return tokenAvailabilityOverride()
        }
        if let env = ProcessInfo.processInfo.environment["CLOUDFLARE_API_TOKEN"], !env.isEmpty {
            return true
        }
        if let stored = (try? keychain.readCloudflareToken()) ?? nil, !stored.isEmpty {
            return true
        }
        return false
    }

    /// Set `phase` and notify the transition hook. All of `runDeploy`'s phase changes route
    /// through here; the synchronous pre-Task `.running` set in `deploy(...)` intentionally does
    /// not (it exists only to close a re-entrancy race and is immediately superseded by
    /// `runDeploy`'s own `.running`), so consumers see exactly one start transition per run.
    private func transition(siteID: String, to newPhase: Phase) {
        phase = newPhase
        onPhaseTransition?(siteID, newPhase)
    }

    private func runDeploy(
        siteID: String,
        siteDirectory: URL,
        configDirectory: URL,
        currentRoutes: [String],
        containerControl: (siteID: String, control: any LocalContainerControl)? = nil,
        suddenTerminationLease: SuddenTerminationController.Lease
    ) async {
        defer { suddenTerminationLease.release() }
        transition(siteID: siteID, to: .running(siteID: siteID, since: Date()))
        logLines = []
        currentMilestone = nil
        failureSummary = nil
        summarizing = false
        summarizationGeneration &+= 1   // invalidate any still-in-flight summary from a prior deploy
        // Captured immediately after the bump — the authoritative "my generation" value for
        // this call's summarization branch. Must NOT be re-read later via the live field, which
        // may have moved on if a second `runDeploy` call started concurrently (see guard below).
        let myGeneration = summarizationGeneration
        drawerPresented = true
        blockedPresented = false

        let sources = Set(["deploy:\(siteID)", "deploy:\(siteID):build"])

        // Subscribe BEFORE the deploy starts so we can't miss early build lines.
        let subscription = await logCenter.subscribe()
        let logTask = Task { @MainActor [weak self] in
            for await line in subscription.stream where sources.contains(line.source) {
                self?.logLines.append(line)
            }
        }

        // Select the executor: in-container when the runtime is a started container;
        // explicit unavailable result otherwise. The token source always comes from the
        // injected `command` so the test-injection path (a fully pre-built
        // `DeployCommand`) continues to work unmodified.
        let activeCommand: DeployCommand
        if let cc = containerControl {
            activeCommand = DeployCommand(
                tokenSource: command.tokenSource,
                executor: ContainerDeployExecutor(
                    control: cc.control,
                    siteID: cc.siteID,
                    logCenter: logCenter
                )
            )
        } else {
            activeCommand = command
        }

        let result = await activeCommand.deploy(
            siteID: siteID,
            siteDirectory: siteDirectory,
            configDirectory: configDirectory,
            currentRoutes: currentRoutes,
            onPreflight: { [weak self] outcome in
                // The callback fires inside DeployCommand's actor isolation; hop to
                // MainActor before touching our @Observable state or the consumer's
                // closure (which likely mutates SwiftUI state too).
                Task { @MainActor in
                    self?.onScanComplete?(outcome)
                }
            },
            onProgress: { [weak self] progress in
                // last-write-wins: each milestone fully replaces the label, so out-of-order delivery across these hops is benign
                Task { @MainActor in
                    self?.currentMilestone = progress.label
                    self?.onMilestone?(siteID, progress)
                }
            }
        )

        subscription.cancel()
        _ = await logTask.value

        currentMilestone = nil
        switch result {
        case .succeeded(let url, let duration):
            transition(siteID: siteID, to: .succeeded(url: url, duration: duration))
            // Fire-and-forget: webmention sends are best-effort and must never block or affect
            // the deploy result the user watches. Progress/failures surface only in LogCenter.
            Task.detached { [webmentionCommand] in
                await webmentionCommand.send(
                    siteID: siteID,
                    siteDirectory: siteDirectory,
                    configDirectory: configDirectory,
                    siteBase: url
                )
            }
            // POSSE is independently best-effort so a slow social API never delays webmentions or
            // changes the deploy result. Its own actor serializes overlapping runs per site.
            Task.detached { [posseCommand] in
                await posseCommand.syndicate(
                    siteID: siteID,
                    siteDirectory: siteDirectory,
                    configDirectory: configDirectory,
                    siteBase: url
                )
            }
        case .failed(let reason, let exit):
            transition(siteID: siteID, to: .failed(reason: reason, exitCode: exit))
            let capturedLog = logText   // snapshot before the suspension; a later deploy clears logLines
            summarizing = true
            let summary = await DeployFailureSummaryRequest.run(
                logText: capturedLog,
                siteID: siteID,
                siteDirectory: siteDirectory,
                using: summarizer
            )
            // Drop the result if another deploy started while we were summarizing — it has already
            // reset failureSummary/summarizing and we must not clobber its state.
            guard summarizationGeneration == myGeneration else { return }
            failureSummary = summary
            summarizing = false
        case .blocked(let failures, let warnings):
            transition(siteID: siteID, to: .blocked(failures: failures, warnings: warnings))
            // For the blocked outcome the modal sheet carries the actionable info; the
            // streaming-log drawer would just be noise.
            drawerPresented = false
            blockedPresented = true
        }
    }
}
