import Foundation

/// A site's GitHub remote, derived from `origin`. Source of truth for "is this site published?".
public struct RemoteRepo: Sendable, Equatable {
    public let url: URL      // browser URL, e.g. https://github.com/owner/name
    public let owner: String
    public let name: String

    public init(url: URL, owner: String, name: String) {
        self.url = url
        self.owner = owner
        self.name = name
    }

    /// Parse a git remote URL (https or scp-like ssh) into owner/name + a browser URL.
    /// Returns nil for empty/unparseable input or if the host is not github.com.
    public static func parse(remoteURL raw: String) -> RemoteRepo? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var owner = "", name = "", host = ""
        if trimmed.hasPrefix("git@") || (!trimmed.contains("://") && trimmed.contains(":")) {
            // scp-like: git@github.com:owner/name.git — host is between "@" and ":"
            guard let at = trimmed.firstIndex(of: "@"), let colon = trimmed.firstIndex(of: ":") else { return nil }
            // A ":" before the "@" (e.g. "host:user@path") would make the host range start > end
            // and trap on the subscript. Reject rather than crash.
            guard at < colon else { return nil }
            host = String(trimmed[trimmed.index(after: at)..<colon])
            let path = trimmed[trimmed.index(after: colon)...].split(separator: "/")
            guard path.count >= 2 else { return nil }
            owner = String(path[path.count - 2])
            name = String(path[path.count - 1])
        } else if let u = URL(string: trimmed), let urlHost = u.host {
            host = urlHost
            let comps = u.path.split(separator: "/")
            guard comps.count >= 2 else { return nil }
            owner = String(comps[comps.count - 2])
            name = String(comps[comps.count - 1])
        } else {
            return nil
        }

        // Only accept github.com remotes — non-GitHub origins (GitLab, Bitbucket, etc.) must not
        // produce a broken github.com browse URL or mislead consumers about published state.
        guard host.lowercased() == "github.com" || host.lowercased() == "www.github.com" else { return nil }

        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        guard !owner.isEmpty, !name.isEmpty, let browse = URL(string: "https://github.com/\(owner)/\(name)") else {
            return nil
        }
        return RemoteRepo(url: browse, owner: owner, name: name)
    }
}

/// User-facing failure from the bootstrap pipeline.
public struct RepoBootstrapError: Error, Equatable, Sendable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// Run a subprocess and capture its output. Production: `ProcessSupervisor.shared.run`.
public typealias RepoCommandRunner = @Sendable (_ executable: URL, _ args: [String], _ cwd: URL?) async throws -> ProcessSupervisor.RunResult

/// Creates the remote repository and pushes to it. The part that differs between `gh` (DevID)
/// and a future REST/token impl (#71). Git-side preflight lives in `RepoBootstrap`, not here.
public protocol RepoProvider: Sendable {
    /// True if the provider has usable credentials (no interactive prompt needed).
    func isAuthenticated() async -> Bool
    /// Create the remote repo, wire `origin` in `source`, and push. Throws `RepoBootstrapError`.
    func createAndPush(name: String, isPrivate: Bool, source: URL) async throws -> RemoteRepo
}

/// GitHub provider backed by the `gh` CLI. Reuses `gh`'s credential store (per CLAUDE.md the app
/// does not own GitHub creds). DevID only — the UI that drives it is `#if !ANGLESITE_MAS`.
public struct GHRepoProvider: RepoProvider {
    private let run: RepoCommandRunner
    private let env = URL(fileURLWithPath: "/usr/bin/env")

    public init(run: @escaping RepoCommandRunner) { self.run = run }

    public func isAuthenticated() async -> Bool {
        guard let r = try? await run(env, ["gh", "auth", "status"], nil) else { return false }
        return r.exitCode == 0
    }

    public func createAndPush(name: String, isPrivate: Bool, source: URL) async throws -> RemoteRepo {
        let visibility = isPrivate ? "--private" : "--public"
        // `--` terminates flag parsing, so `name` (the positional) must come last, after all flags —
        // it guards a future caller passing a leading-hyphen name from having it read as a flag.
        // (`gh repo create -- name --private` is rejected by gh; the terminator must follow the flags.)
        let create = try await run(env,
            ["gh", "repo", "create", visibility,
             "--source", source.path(percentEncoded: false), "--remote", "origin", "--push", "--", name],
            source)
        guard create.exitCode == 0 else {
            throw RepoBootstrapError(reason: Self.firstLine(create.stderr) ?? "Couldn't create the GitHub repository.")
        }
        // origin is now set; read it back as the source of truth rather than parsing gh's output.
        let originRead = try await run(env, ["git", "remote", "get-url", "origin"], source)
        guard originRead.exitCode == 0, let repo = RemoteRepo.parse(remoteURL: originRead.stdout) else {
            throw RepoBootstrapError(reason: "Repository created, but couldn't read its origin URL.")
        }
        return repo
    }

    private static func firstLine(_ s: String) -> String? {
        s.split(whereSeparator: \.isNewline).map(String.init).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }
}
