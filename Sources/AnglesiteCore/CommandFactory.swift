import Foundation

/// Constructs the deterministic command actors the App Intents wrap. The live implementation
/// returns the real zero-arg actors; tests inject a fake whose actors are built with the
/// actors' existing closure seams to return canned `Result`s (see `SiteOperationsTests`).
public protocol CommandFactory: Sendable {
    func deploy() -> DeployCommand
    func backup() -> BackupCommand
    func audit() -> AuditCommand
}

public struct LiveCommandFactory: CommandFactory {
    public init() {}
    public func deploy() -> DeployCommand { DeployCommand() }
    public func backup() -> BackupCommand { BackupCommand() }
    public func audit() -> AuditCommand { AuditCommand() }
}
