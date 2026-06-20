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
    /// Returns nil for empty/unparseable input.
    public static func parse(remoteURL raw: String) -> RemoteRepo? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var owner = "", name = ""
        if trimmed.hasPrefix("git@") || (!trimmed.contains("://") && trimmed.contains(":")) {
            // scp-like: git@github.com:owner/name.git
            guard let colon = trimmed.firstIndex(of: ":") else { return nil }
            let path = trimmed[trimmed.index(after: colon)...].split(separator: "/")
            guard path.count >= 2 else { return nil }
            owner = String(path[path.count - 2])
            name = String(path[path.count - 1])
        } else if let u = URL(string: trimmed), u.host != nil {
            let comps = u.path.split(separator: "/")
            guard comps.count >= 2 else { return nil }
            owner = String(comps[comps.count - 2])
            name = String(comps[comps.count - 1])
        } else {
            return nil
        }

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
