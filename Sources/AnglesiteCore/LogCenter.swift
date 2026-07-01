import Foundation

/// Central, in-memory fan-out for subprocess log lines.
///
/// Every long-running process launched through `ProcessSupervisor.launch(...)` streams its
/// stdout/stderr lines into a `LogCenter`. Consumers — the Debug pane, runtime readiness
/// regex, the MCP client's framing — subscribe via `subscribe()` and receive an `AsyncStream`
/// of every subsequent line. Recent history is retained in a bounded ring buffer so a newly
/// opened Debug pane can show the immediate past.
///
/// Filtering by source/stream is done on the subscriber side. Keeping the fan-out cheap and
/// uniform means we have a single, easy-to-reason-about path for every byte coming off a child
/// process — which is how the app stays diagnosable when something inevitably goes sideways
/// in a user's environment.
public actor LogCenter {
    /// Shared instance used by `ProcessSupervisor` by default. Tests build their own.
    public static let shared = LogCenter()

    public enum Stream: String, Sendable, Equatable, CaseIterable {
        case stdout
        case stderr
    }

    public struct LogLine: Sendable, Equatable, Identifiable {
        public let id: UInt64
        public let timestamp: Date
        public let source: String
        public let stream: Stream
        public let text: String

        public init(id: UInt64, timestamp: Date, source: String, stream: Stream, text: String) {
            self.id = id
            self.timestamp = timestamp
            self.source = source
            self.stream = stream
            self.text = text
        }
    }

    /// Handle returned by `subscribe()`. Holds the stream consumers iterate, and a `cancel()`
    /// method that finishes the underlying continuation — needed because `AsyncStream` iteration
    /// doesn't unblock on task cancellation alone; the producer side has to call `finish()`.
    public struct Subscription: Sendable {
        public let stream: AsyncStream<LogLine>
        private let continuation: AsyncStream<LogLine>.Continuation

        init(stream: AsyncStream<LogLine>, continuation: AsyncStream<LogLine>.Continuation) {
            self.stream = stream
            self.continuation = continuation
        }

        /// Ends the subscription. The iterator returns `nil` on its next `next()`, the for-await
        /// loop exits, and `LogCenter` drops the registration via `onTermination`.
        public func cancel() {
            continuation.finish()
        }
    }

    public let bufferCapacity: Int

    private var nextID: UInt64 = 0
    private var buffer: [LogLine] = []
    private var subscribers: [UUID: AsyncStream<LogLine>.Continuation] = [:]

    public init(bufferCapacity: Int = 5000) {
        precondition(bufferCapacity > 0, "bufferCapacity must be positive")
        self.bufferCapacity = bufferCapacity
        self.buffer.reserveCapacity(bufferCapacity)
    }

    /// Records a line and pushes it to every active subscriber.
    public func append(source: String, stream: Stream, text: String, timestamp: Date = Date()) {
        let id = nextID
        nextID &+= 1
        let line = LogLine(id: id, timestamp: timestamp, source: source, stream: stream, text: text)
        buffer.append(line)
        if buffer.count > bufferCapacity {
            buffer.removeFirst(buffer.count - bufferCapacity)
        }
        for continuation in subscribers.values {
            continuation.yield(line)
        }
    }

    /// Snapshot of currently retained lines, oldest first.
    public func snapshot() -> [LogLine] {
        buffer
    }

    /// Subscribes to all future log lines. The returned `Subscription` exposes the stream and a
    /// `cancel()` method that finishes iteration — call it from cleanup paths so consumers don't
    /// hang in `for await`. Dropping the subscription also fires `onTermination` and unregisters.
    public func subscribe() -> Subscription {
        let (stream, continuation) = AsyncStream<LogLine>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeSubscriber(id) }
        }
        return Subscription(stream: stream, continuation: continuation)
    }

    /// Number of live subscribers. Exposed for tests; not part of the public contract.
    public func subscriberCount() -> Int {
        subscribers.count
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}

public extension Sequence where Element == LogCenter.LogLine {
    /// Filters log lines for the Debug pane:
    /// - `source`: `nil` keeps every source; otherwise an exact match.
    /// - `stream`: `nil` keeps both streams; otherwise an exact match.
    /// - `query`: trimmed; when non-empty, a case-insensitive substring match against the
    ///   line's source *or* text. Whitespace-only queries are treated as empty.
    func filtered(source: String?, stream: LogCenter.Stream?, query: String) -> [LogCenter.LogLine] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return filter { line in
            if let source, line.source != source { return false }
            if let stream, line.stream != stream { return false }
            if !needle.isEmpty {
                guard line.source.lowercased().contains(needle) || line.text.lowercased().contains(needle) else {
                    return false
                }
            }
            return true
        }
    }

    /// Renders the lines as plain text — one `HH:mm:ss.SSS  [source/stream]  text` row each —
    /// for the Debug pane's copy-to-clipboard and save-to-file actions.
    func exportText(timestampFormat: String = "HH:mm:ss.SSS") -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = timestampFormat
        return map { line in
            "\(formatter.string(from: line.timestamp))  [\(line.source)/\(line.stream.rawValue)]  \(line.text)"
        }.joined(separator: "\n")
    }
}
