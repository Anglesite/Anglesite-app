import AppKit
import AnglesiteCore
import AnglesiteIntents

actor AppleScriptCommandEnvironment {
    static let shared = AppleScriptCommandEnvironment()

    private var contentGraph = SiteContentGraph()

    func configure(contentGraph: SiteContentGraph) {
        self.contentGraph = contentGraph
    }

    func service() -> AppleScriptCommandService {
        AppleScriptCommandService(graph: contentGraph)
    }
}

private extension NSScriptCommand {
    var directTextParameter: String? {
        directParameter as? String
    }

    func requiredDirectTextParameter() throws -> String {
        if let value = directTextParameter?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        throw AppleScriptCommandService.CommandError.emptySiteSpecifier
    }

    func stringArgument(named names: String...) -> String? {
        for name in names {
            if let value = evaluatedArguments?[name] as? String {
                return value
            }
        }
        return nil
    }

    func requiredStringArgument(named names: String...) throws -> String {
        if let value = stringArgument(named: names)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        throw AppleScriptArgumentError.missing(names[0])
    }

    private func stringArgument(named names: [String]) -> String? {
        for name in names {
            if let value = evaluatedArguments?[name] as? String {
                return value
            }
        }
        return nil
    }

    func boolArgument(named names: String...) -> Bool {
        for name in names {
            if let value = evaluatedArguments?[name] as? Bool {
                return value
            }
            if let value = evaluatedArguments?[name] as? NSNumber {
                return value.boolValue
            }
        }
        return false
    }

    func runCommand(_ body: @escaping @Sendable () async throws -> String) -> Any? {
        suspendExecution()
        let command = AppleScriptCommandBox(self)

        Task {
            do {
                let result = try await body()
                await MainActor.run {
                    command.value.resumeExecution(withResult: result)
                }
            } catch {
                await MainActor.run {
                    command.value.scriptErrorNumber = -10000
                    command.value.scriptErrorString = error.localizedDescription
                    command.value.resumeExecution(withResult: nil)
                }
            }
        }

        return nil
    }
}

private final class AppleScriptCommandBox: @unchecked Sendable {
    let value: NSScriptCommand

    init(_ value: NSScriptCommand) {
        self.value = value
    }
}

private enum AppleScriptArgumentError: LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name):
            return "Missing required AppleScript parameter: \(name)."
        }
    }
}

@objc(OpenSiteCommand)
final class OpenSiteCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let specifier: String
        do {
            specifier = try requiredDirectTextParameter()
        } catch {
            scriptErrorNumber = -10000
            scriptErrorString = error.localizedDescription
            return nil
        }
        return runCommand {
            let service = await AppleScriptCommandEnvironment.shared.service()
            let site = try await service.openSite(specifier)
            await MainActor.run {
                WindowRouter.shared.requestOpen(siteID: site.id)
            }
            return "Opened \(site.name)."
        }
    }
}

@objc(DeploySiteCommand)
final class DeploySiteCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let specifier: String
        do {
            specifier = try requiredDirectTextParameter()
        } catch {
            scriptErrorNumber = -10000
            scriptErrorString = error.localizedDescription
            return nil
        }
        let allowingUnattended = boolArgument(named: "allowing unattended", "allowingUnattended", "alun")
        return runCommand {
            let service = await AppleScriptCommandEnvironment.shared.service()
            return try await service.deploySite(
                specifier,
                allowingUnattended: allowingUnattended
            )
        }
    }
}

@objc(BackupSiteCommand)
final class BackupSiteCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let specifier: String
        do {
            specifier = try requiredDirectTextParameter()
        } catch {
            scriptErrorNumber = -10000
            scriptErrorString = error.localizedDescription
            return nil
        }
        return runCommand {
            let service = await AppleScriptCommandEnvironment.shared.service()
            return try await service.backupSite(specifier)
        }
    }
}

@objc(AuditSiteCommand)
final class AuditSiteCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let specifier: String
        do {
            specifier = try requiredDirectTextParameter()
        } catch {
            scriptErrorNumber = -10000
            scriptErrorString = error.localizedDescription
            return nil
        }
        return runCommand {
            let service = await AppleScriptCommandEnvironment.shared.service()
            return try await service.auditSite(specifier)
        }
    }
}

@objc(SiteStatusCommand)
final class SiteStatusCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let specifier: String
        do {
            specifier = try requiredDirectTextParameter()
        } catch {
            scriptErrorNumber = -10000
            scriptErrorString = error.localizedDescription
            return nil
        }
        return runCommand {
            let service = await AppleScriptCommandEnvironment.shared.service()
            return try await service.siteStatus(specifier)
        }
    }
}

@objc(AddPageCommand)
final class AddPageCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let specifier: String
        let name: String
        let route: String?
        do {
            specifier = try requiredDirectTextParameter()
            name = try requiredStringArgument(named: "name")
            route = stringArgument(named: "route", "rout")
        } catch {
            scriptErrorNumber = -10000
            scriptErrorString = error.localizedDescription
            return nil
        }
        return runCommand {
            let service = await AppleScriptCommandEnvironment.shared.service()
            return try await service.addPage(
                specifier,
                name: name,
                route: route
            )
        }
    }
}

@objc(AddPostCommand)
final class AddPostCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let specifier: String
        let title: String
        let collection: String?
        let slug: String?
        do {
            specifier = try requiredDirectTextParameter()
            title = try requiredStringArgument(named: "title", "titl")
            collection = stringArgument(named: "collection", "coll")
            slug = stringArgument(named: "slug")
        } catch {
            scriptErrorNumber = -10000
            scriptErrorString = error.localizedDescription
            return nil
        }
        return runCommand {
            let service = await AppleScriptCommandEnvironment.shared.service()
            return try await service.addPost(
                specifier,
                title: title,
                collection: collection,
                slug: slug
            )
        }
    }
}
