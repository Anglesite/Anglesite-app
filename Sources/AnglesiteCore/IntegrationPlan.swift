public typealias Answers = [String: String]   // field key → value; chosen provider under "provider"

public enum PlannedStep: Sendable, Equatable {
    case createFile(relativePath: String, contents: String)
    case upsertConfig([ConfigKV])
    case injectAnchor(relativeFile: String, anchor: String, id: String, snippet: String, style: MarkerInjector.CommentStyle)
    case addCSP([String])
    case appendLine(relativePath: String, line: String)
}

public struct ConfigKV: Sendable, Equatable {
    public let key: String
    public let value: String
    public init(key: String, value: String) { self.key = key; self.value = value }
}

public struct PlanWarning: Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public struct OperationPlan: Sendable, Equatable {
    public let integrationID: IntegrationID
    public let steps: [PlannedStep]
    public let warnings: [PlanWarning]
    public init(integrationID: IntegrationID, steps: [PlannedStep], warnings: [PlanWarning]) {
        self.integrationID = integrationID; self.steps = steps; self.warnings = warnings
    }
    public var summary: String {
        var lines: [String] = []
        for step in steps {
            switch step {
            case .createFile(let path, _): lines.append("Create \(path)")
            case .upsertConfig(let kvs): lines.append("Set \(kvs.count) config key\(kvs.count == 1 ? "" : "s")")
            case .injectAnchor(let file, _, _, _, _): lines.append("Add a component to \(file)")
            case .addCSP(let domains): lines.append("Allow \(domains.count) domain\(domains.count == 1 ? "" : "s") in the site's security policy")
            case .appendLine(let path, _): lines.append("Append a line to \(path)")
            }
        }
        for w in warnings { lines.append("Warning: \(w.message)") }
        return lines.joined(separator: "\n")
    }
}

public enum IntegrationError: Error, Equatable, Sendable {
    case missingRequiredField(key: String)
    case invalidValue(key: String, reason: String)
    case unknownProvider(String)
    case providerRequired
    case siteNotFound
    case templateUnavailable
    /// A staged asset the descriptor copies is absent from the template — a hard error, since
    /// proceeding would inject an `import` for a file that was never written.
    case missingTemplateAsset(path: String)
}
