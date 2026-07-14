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

private enum AppleScriptAsyncBridge {
    static func run<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = AppleScriptAsyncOutcomeBox<T>()

        Task {
            do {
                box.outcome = .success(try await operation())
            } catch {
                box.outcome = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()

        switch box.outcome {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case nil:
            throw AppleScriptCommandService.CommandError.siteNotFound("unknown")
        }
    }
}

private final class AppleScriptAsyncOutcomeBox<T>: @unchecked Sendable {
    var outcome: Result<T, Error>?
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
        if let value = stringArgument(namedAnyOf: names)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        throw AppleScriptArgumentError.missing(names[0])
    }

    private func stringArgument(namedAnyOf names: [String]) -> String? {
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
        do {
            return try AppleScriptAsyncBridge.run(body)
        } catch {
            scriptErrorNumber = -10000
            scriptErrorString = error.localizedDescription
            return nil
        }
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
        do {
            let specifier = try requiredDirectTextParameter()
            let site = try AppleScriptAsyncBridge.run {
                let service = await AppleScriptCommandEnvironment.shared.service()
                return try await service.openSite(specifier)
            }
            openWindow(siteID: site.id)
            return "Opened \(site.name)."
        } catch {
            scriptErrorNumber = -10000
            scriptErrorString = error.localizedDescription
            return nil
        }
    }

    private func openWindow(siteID: String) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                WindowRouter.shared.requestOpen(siteID: siteID)
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    WindowRouter.shared.requestOpen(siteID: siteID)
                }
            }
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
