import Foundation

/// A Cloudflare account as reported by `wrangler whoami`. Both fields are best-effort: the
/// account `name` is `nil` when the whoami table can't be parsed (the token is still valid — the
/// caller falls back to a generic "verified" message), and `email` is `nil` for token auth that
/// isn't associated with a user email.
public struct CloudflareAccount: Sendable, Equatable {
    public let name: String?
    public let email: String?

    public init(name: String?, email: String?) {
        self.name = name
        self.email = email
    }
}

/// Why verifying a pasted Cloudflare token failed, with the user-facing copy the prompt shows.
public enum TokenVerifyError: Error, Equatable, Sendable {
    /// The token was rejected by Cloudflare (bad/expired/insufficient scope).
    case invalidToken
    /// We couldn't reach Cloudflare (DNS/connection failure).
    case network
    /// We couldn't run wrangler at all (missing binary, spawn failure, etc.).
    case unavailable(String)

    public var userMessage: String {
        switch self {
        case .invalidToken:
            return "That token didn’t work. Make sure you picked the “Edit Cloudflare Workers” template and copied the whole token."
        case .network:
            return "Couldn’t reach Cloudflare. Check your connection and try again."
        case .unavailable(let reason):
            return reason
        }
    }
}

/// Verifies a Cloudflare API token before it's persisted, so a bad token is caught at the point of
/// entry instead of failing later inside `wrangler deploy`.
public protocol TokenVerifying: Sendable {
    func verify(token: String, siteDirectory: URL) async -> Result<CloudflareAccount, TokenVerifyError>
}

/// Verifies a token by running the site's own `wrangler whoami` with the token in the environment,
/// through `ProcessSupervisor` — the same supervised spawn path the deploy uses, so it needs no new
/// networking and inherits the MAS sandbox's per-site folder grant. The process step is injected
/// (`Runner`) so the parsing/classification logic is unit-testable without spawning Node.
public struct WranglerTokenVerifier: TokenVerifying {
    /// Runs `wrangler whoami` for `siteDirectory` with `token` in the environment, returning its
    /// captured output. Throws if the process can't be spawned.
    public typealias Runner = @Sendable (_ token: String, _ siteDirectory: URL) async throws -> ProcessSupervisor.RunResult

    private let run: Runner

    public init(run: @escaping Runner = WranglerTokenVerifier.defaultRunner) {
        self.run = run
    }

    public func verify(token: String, siteDirectory: URL) async -> Result<CloudflareAccount, TokenVerifyError> {
        let result: ProcessSupervisor.RunResult
        do {
            result = try await run(token, siteDirectory)
        } catch {
            return .failure(.unavailable("Couldn’t run wrangler to check the token: \(error)"))
        }

        guard result.exitCode == 0 else {
            return .failure(Self.classifyFailure(stdout: result.stdout, stderr: result.stderr))
        }

        // Exit 0 means the token is valid; the account name is a best-effort nicety.
        return .success(Self.parseWhoami(result.stdout) ?? CloudflareAccount(name: nil, email: nil))
    }

    // MARK: Parsing

    /// Extracts the account name (and email, if present) from `wrangler whoami` output. Returns
    /// `nil` when no account table is recognizable, so the caller can still treat a zero-exit run
    /// as verified.
    static func parseWhoami(_ stdout: String) -> CloudflareAccount? {
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Find the "Account Name | Account ID" header, then the first data row beneath it.
        guard let headerIndex = lines.firstIndex(where: {
            $0.contains("Account Name") && $0.contains("Account ID")
        }) else {
            return nil
        }

        let name = lines[(headerIndex + 1)...]
            .lazy
            .compactMap { Self.firstCell(in: $0) }
            .first

        guard let name, !name.isEmpty else { return nil }
        return CloudflareAccount(name: name, email: Self.email(in: stdout))
    }

    /// Returns the trimmed first table cell of a box-drawing row (`│ a │ b │`), or `nil` for
    /// separators (`├──┼──┤`) and non-table lines.
    private static func firstCell(in line: String) -> String? {
        guard line.contains("│") else { return nil }
        // Separator rows are made of box-drawing line/junction characters only.
        if line.contains("├") || line.contains("┼") || line.contains("┤") { return nil }
        let cells = line
            .split(separator: "│", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return cells.first
    }

    /// Pulls the email out of "…associated with the email foo@bar.com." if present.
    private static func email(in stdout: String) -> String? {
        guard let range = stdout.range(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, options: .regularExpression) else {
            return nil
        }
        return String(stdout[range])
    }

    // MARK: Failure classification

    /// Maps a failed `wrangler whoami` run to a `TokenVerifyError` by sniffing its output for
    /// network-level failures; anything else is treated as a rejected token.
    static func classifyFailure(stdout: String, stderr: String) -> TokenVerifyError {
        let combined = (stdout + "\n" + stderr).lowercased()
        let networkMarkers = ["getaddrinfo", "enotfound", "econnrefused", "etimedout", "network", "fetch failed", "socket hang up"]
        if networkMarkers.contains(where: combined.contains) {
            return .network
        }
        return .invalidToken
    }

    // MARK: Default runner

    /// Production runner: resolves the site's `node_modules/.bin/wrangler` and runs `whoami` under
    /// the vendored Node, with the token in the environment, through `ProcessSupervisor`.
    public static let defaultRunner: Runner = { token, siteDirectory in
        let wranglerBin = siteDirectory
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(".bin", isDirectory: true)
            .appendingPathComponent("wrangler")
        guard FileManager.default.isExecutableFile(atPath: wranglerBin.path) else {
            throw TokenVerifyError.unavailable("wrangler isn’t installed — run `npm install` in this site")
        }
        guard let node = NodeRuntime.bundledExecutableURL else {
            throw TokenVerifyError.unavailable("the embedded Node runtime isn’t bundled (rebuild the app)")
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CLOUDFLARE_API_TOKEN"] = token

        return try await ProcessSupervisor.shared.run(
            executable: node,
            arguments: [wranglerBin.path, "whoami"],
            environment: environment,
            currentDirectoryURL: siteDirectory
        )
    }
}
