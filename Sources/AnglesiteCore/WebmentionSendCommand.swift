import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Actor orchestrator for one site's webmention-send pass, run after a successful deploy.
/// Builds the site's `SocialPublishPlan` (siteBase = the just-deployed URL), diffs it against the
/// site's `WebmentionSentLog`, sends each pending pair, persists successes, and streams
/// progress/results into `LogCenter` under source `"webmention:<siteID>"`. Best-effort — never
/// throws; failures are logged, not surfaced as a thrown error, since this runs detached from the
/// deploy result the user actually watches (`DeployModel.runDeploy`).
public actor WebmentionSendCommand {
    private let transport: WebmentionEndpointDiscovery.Transport
    private let logCenter: LogCenter
    private let now: () -> Date

    public init(
        transport: @escaping WebmentionEndpointDiscovery.Transport = WebmentionSendCommand.defaultTransport,
        logCenter: LogCenter = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.logCenter = logCenter
        self.now = now
    }

    public func send(siteID: String, siteDirectory: URL, configDirectory: URL, siteBase: URL) async {
        let logSource = "webmention:\(siteID)"

        let plan: SocialPublishPlan.Plan
        do {
            plan = try SocialPublishPlan.build(projectRoot: siteDirectory, siteBase: siteBase)
        } catch {
            await logCenter.append(
                source: logSource, stream: .stderr,
                text: "webmention: couldn't build publish plan: \(error)"
            )
            return
        }
        guard plan.webmentionCount > 0 else { return }

        let log = WebmentionSentLog.load(from: configDirectory) ?? WebmentionSentLog()
        let pending = log.pending(in: plan)
        guard !pending.isEmpty else { return }

        await logCenter.append(
            source: logSource, stream: .stdout,
            text: "webmention: sending \(pending.count) webmention(s)"
        )

        var sentPairs: [WebmentionTargetPair] = []
        for pair in pending {
            let outcome = await WebmentionSender.send(source: pair.source, target: pair.target, transport: transport)
            switch outcome {
            case .sent(let endpoint, let statusCode):
                await logCenter.append(
                    source: logSource, stream: .stdout,
                    text: "webmention: sent \(pair.source.absoluteString) -> \(pair.target.absoluteString) via \(endpoint.absoluteString) (HTTP \(statusCode))"
                )
                sentPairs.append(pair)
            case .noEndpointDiscovered:
                await logCenter.append(
                    source: logSource, stream: .stdout,
                    text: "webmention: no endpoint declared by \(pair.target.absoluteString), skipping"
                )
            case .requestFailed(let reason):
                await logCenter.append(
                    source: logSource, stream: .stderr,
                    text: "webmention: \(pair.source.absoluteString) -> \(pair.target.absoluteString) failed: \(reason)"
                )
            }
        }

        guard !sentPairs.isEmpty else { return }
        let updated = log.recording(sentPairs, now: now)
        do {
            try updated.save(to: configDirectory)
        } catch {
            await logCenter.append(
                source: logSource, stream: .stderr,
                text: "webmention: couldn't persist sent log: \(error)"
            )
        }
    }

    /// Production transport: a plain `URLSession` request.
    public static let defaultTransport: WebmentionEndpointDiscovery.Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
