// `FoundationNetworking` (non-Darwin) has no `URLSession.bytes(for:)`/`AsyncBytes`, which
// `HTTPTransport` needs to read a `text/event-stream` response incrementally instead of
// buffering the whole (indefinite, keep-alive) body — see the comment on `HTTPTransport.send`.
// This is the off-Darwin replacement: a `URLSessionDataDelegate`-driven reader that streams
// body chunks as they arrive, with the same "don't wait for the connection to close" property.
#if !canImport(Darwin)
import Foundation
import FoundationNetworking

/// Runs one request and exposes its response body as a stream of `Data` chunks, delivered as
/// the delegate receives them (not buffered until the connection closes). One instance per
/// request — not reused.
final class HTTPStreamingRunner: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var responseContinuation: CheckedContinuation<URLResponse, Error>?
    private let bodyContinuation: AsyncThrowingStream<Data, Error>.Continuation
    let bodyStream: AsyncThrowingStream<Data, Error>

    override init() {
        (bodyStream, bodyContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        super.init()
    }

    /// Starts `request` and suspends until the response headers arrive; the body streams
    /// separately via `bodyStream`. `configuration` is copied from the caller's `URLSession` so
    /// e.g. test `URLProtocol` stubs registered on it still apply.
    func start(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> URLResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            responseContinuation = continuation
            lock.unlock()
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            session.dataTask(with: request).resume()
        }
    }

    /// Splits `bodyStream` into lines (delimited by `\n`, with an optional trailing `\r`
    /// stripped, mirroring `AsyncBytes.lines` on Darwin), yielding a final partial line if the
    /// stream ends without a trailing newline.
    func lines() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                var buffer = Data()
                do {
                    for try await chunk in bodyStream {
                        buffer.append(chunk)
                        while let newline = buffer.firstIndex(of: 0x0A) {
                            var lineData = buffer[buffer.startIndex..<newline]
                            if lineData.last == 0x0D { lineData = lineData.dropLast() }
                            continuation.yield(String(decoding: lineData, as: UTF8.self))
                            buffer.removeSubrange(buffer.startIndex...newline)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(String(decoding: buffer, as: UTF8.self))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        let continuation = responseContinuation
        responseContinuation = nil
        lock.unlock()
        continuation?.resume(returning: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bodyContinuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = responseContinuation
        responseContinuation = nil
        lock.unlock()
        if let error {
            continuation?.resume(throwing: error)
            bodyContinuation.finish(throwing: error)
        } else {
            bodyContinuation.finish()
        }
    }
}
#endif
