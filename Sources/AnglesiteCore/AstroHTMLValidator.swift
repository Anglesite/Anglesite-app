import Foundation

public protocol CustomAnalyticsHTMLValidating: Sendable {
    func validationMessage(for html: String, siteDirectory: URL) async -> String?
}

public struct AstroHTMLValidator: CustomAnalyticsHTMLValidating, Sendable {
    public typealias CommandRunner = @Sendable (_ executable: URL, _ arguments: [String], _ cwd: URL?) async throws -> ProcessSupervisor.RunResult

    private let nodeExecutable: @Sendable () -> URL?
    private let run: CommandRunner

    public init(
        nodeExecutable: @escaping @Sendable () -> URL? = { nil },
        run: @escaping CommandRunner = { executable, arguments, cwd in
            try await ProcessSupervisor.shared.run(
                executable: executable,
                arguments: arguments,
                currentDirectoryURL: cwd
            )
        }
    ) {
        self.nodeExecutable = nodeExecutable
        self.run = run
    }

    public func validationMessage(for html: String, siteDirectory: URL) async -> String? {
        let snippet = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snippet.isEmpty else { return nil }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: siteDirectory.appendingPathComponent("node_modules/@astrojs/compiler/package.json").path) else {
            return "Custom analytics HTML couldn't be validated because Astro dependencies are missing. Run npm install in this site and try again."
        }
        guard let node = nodeExecutable() else {
            return "Custom analytics HTML validation must run in the container runtime; host Node has been retired."
        }

        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("anglesite-astro-html-validation-\(UUID().uuidString)", isDirectory: true)
        let cleanup: @Sendable () -> Void = {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        do {
            return try await withTaskCancellationHandler {
                try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
                defer { cleanup() }

                let snippetURL = workDirectory.appendingPathComponent("custom-analytics.html")
                let scriptURL = workDirectory.appendingPathComponent("validate-custom-analytics.mjs")
                try snippet.write(to: snippetURL, atomically: true, encoding: .utf8)
                try Self.validationScript.write(to: scriptURL, atomically: true, encoding: .utf8)

                let result = try await run(
                    node,
                    [scriptURL.path, siteDirectory.path, snippetURL.path],
                    siteDirectory
                )
                guard result.exitCode != 0 else { return nil }
                let message = [result.stderr, result.stdout]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                return "Custom analytics HTML is invalid: \(Self.friendlyMessage(message))"
            } onCancel: {
                cleanup()
            }
        } catch {
            return "Custom analytics HTML couldn't be validated: \(error.localizedDescription)"
        }
    }

    private static func friendlyMessage(_ message: String?) -> String {
        guard let message, !message.isEmpty else {
            return "Astro couldn't parse the snippet."
        }
        if message.contains("Cannot read properties of undefined")
            || message.contains("index out of range") {
            return "Astro couldn't parse the snippet. Check for incomplete tags or script blocks."
        }
        return message
    }

    private static let validationScript = #"""
    import { createRequire } from 'node:module';
    import { readFileSync } from 'node:fs';
    import { pathToFileURL } from 'node:url';
    import { join } from 'node:path';

    const siteDirectory = process.argv[2];
    const snippetPath = process.argv[3];
    const require = createRequire(pathToFileURL(join(siteDirectory, 'package.json')));
    const { convertToTSX } = require('@astrojs/compiler/sync');
    const snippet = readFileSync(snippetPath, 'utf8');
    const source = `---
    ---
    <html>
      <head>
    ${snippet}
      </head>
      <body></body>
    </html>
    `;

    try {
      const result = convertToTSX(source, {
        filename: 'AnglesiteCustomAnalytics.astro',
        includeScripts: true,
        includeStyles: true,
      });
      const diagnostic = (result.diagnostics || []).find((item) => item.severity === 1);
      if (diagnostic) {
        const location = diagnostic.location
          ? `${diagnostic.location.line}:${diagnostic.location.column}: `
          : '';
        console.error(`${location}${diagnostic.text || 'Astro reported invalid HTML.'}`);
        process.exit(1);
      }
    } catch (error) {
      console.error(error?.message || String(error));
      process.exit(1);
    }
    """#
}
