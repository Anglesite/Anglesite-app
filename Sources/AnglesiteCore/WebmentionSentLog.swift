import Foundation

/// A `(source, target)` webmention pair — the unit `WebmentionSentLog` tracks and
/// `WebmentionSendCommand` sends.
public struct WebmentionTargetPair: Equatable, Sendable {
    public let source: URL
    public let target: URL

    public init(source: URL, target: URL) {
        self.source = source
        self.target = target
    }
}

/// Per-site record of `(source, target)` webmention pairs already sent successfully, persisted at
/// `Config/webmention-sent.json` — app-owned state, never committed to the site's git repo (same
/// place as `DeployedRoutesSnapshot`'s `last-deployed-routes.json`). Lets `WebmentionSendCommand`
/// skip pairs it already notified on a prior deploy, instead of re-pinging every target's
/// endpoint on every redeploy.
public struct WebmentionSentLog: Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let source: URL
        public let target: URL
        public let sentAt: Date

        public init(source: URL, target: URL, sentAt: Date) {
            self.source = source
            self.target = target
            self.sentAt = sentAt
        }
    }

    public let sent: [Entry]

    public init(sent: [Entry] = []) {
        self.sent = sent
    }

    public static let filename = "webmention-sent.json"

    private struct Envelope: Codable {
        let sent: [Entry]
    }

    /// `nil` when the file is absent or unreadable — the normal "no prior sends yet" case.
    public static func load(from configDirectory: URL) -> WebmentionSentLog? {
        let url = configDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { return nil }
        return WebmentionSentLog(sent: envelope.sent)
    }

    public func save(to configDirectory: URL) throws {
        let url = configDirectory.appendingPathComponent(Self.filename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Envelope(sent: sent))
        try data.write(to: url, options: .atomic)
    }

    /// Pairs from `plan`'s entries not already recorded as sent.
    public func pending(in plan: SocialPublishPlan.Plan) -> [WebmentionTargetPair] {
        let sentKeys = Set(sent.map { pairKey(source: $0.source, target: $0.target) })
        var result: [WebmentionTargetPair] = []
        for entry in plan.entries {
            for target in entry.webmentionTargets {
                let key = pairKey(source: entry.canonicalURL, target: target)
                if !sentKeys.contains(key) {
                    result.append(WebmentionTargetPair(source: entry.canonicalURL, target: target))
                }
            }
        }
        return result
    }

    /// A new log with `pairs` appended, all stamped with the same `now()` timestamp.
    public func recording(
        _ pairs: [WebmentionTargetPair],
        now: @escaping () -> Date = Date.init
    ) -> WebmentionSentLog {
        let timestamp = now()
        let newEntries = pairs.map { Entry(source: $0.source, target: $0.target, sentAt: timestamp) }
        return WebmentionSentLog(sent: sent + newEntries)
    }

    private func pairKey(source: URL, target: URL) -> String {
        "\(source.absoluteString)\n\(target.absoluteString)"
    }
}
