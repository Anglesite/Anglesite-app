// Sources/AnglesiteCore/IntegrationScaffolder.swift
import Foundation

/// Applies an `OperationPlan` to a site's `Source/` directory idempotently,
/// streaming progress as `SetupStep` values. The only writer in the
/// bucket-3 integration framework.
public actor IntegrationScaffolder {
    public enum SetupStep: Sendable, Equatable {
        case writingFiles, configuring, done(integrationID: String)
        case warning(step: String, message: String)
        case failed(step: String, message: String)
    }

    private let fileManager: FileManager
    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public nonisolated func apply(_ plan: OperationPlan, in sourceDirectory: URL) -> AsyncStream<SetupStep> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            Task {
                await self.run(plan, in: sourceDirectory) { continuation.yield($0) }
                continuation.finish()
            }
        }
    }

    private func run(_ plan: OperationPlan, in source: URL, emit: @Sendable (SetupStep) -> Void) async {
        for w in plan.warnings { emit(.warning(step: "plan", message: w.message)) }
        emit(.writingFiles)
        for step in plan.steps {
            switch step {
            case .createFile(let rel, let contents):
                let url = source.appendingPathComponent(rel)
                do {
                    if fileManager.fileExists(atPath: url.path) {
                        let existing = try String(contentsOf: url, encoding: .utf8)
                        if existing != contents {
                            emit(.warning(step: "writingFiles", message: "Left your edited \(rel) untouched."))
                            continue
                        }
                    } else {
                        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    }
                    try contents.write(to: url, atomically: true, encoding: .utf8)
                } catch { return emit(.failed(step: "writingFiles", message: humanize(error))) }

            case .injectAnchor(let rel, let anchor, let id, let snippet):
                let url = source.appendingPathComponent(rel)
                do {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    switch MarkerInjector.inject(snippet: snippet, withID: id, atAnchor: anchor, into: content) {
                    case .success(let updated): try updated.write(to: url, atomically: true, encoding: .utf8)
                    case .failure(let f): return emit(.failed(step: "writingFiles", message: "\(rel): \(f)"))
                    }
                } catch { return emit(.failed(step: "writingFiles", message: humanize(error))) }

            case .upsertConfig(let kvs):
                emit(.configuring)
                let url = source.appendingPathComponent(".site-config")
                let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let updated = SiteConfigFile.upsert(kvs.map { ($0.key, $0.value) }, into: current)
                do { try updated.write(to: url, atomically: true, encoding: .utf8) }
                catch { return emit(.failed(step: "configuring", message: humanize(error))) }

            case .addCSP(let domains):
                emit(.configuring)
                let url = source.appendingPathComponent(".site-config")
                let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let updated = SiteConfigFile.addCSPDomains(domains, into: current)
                do { try updated.write(to: url, atomically: true, encoding: .utf8) }
                catch { return emit(.failed(step: "configuring", message: humanize(error))) }
            }
        }
        emit(.done(integrationID: plan.integrationID.rawValue))
    }

    private func humanize(_ error: Error) -> String { (error as NSError).localizedDescription }
}
