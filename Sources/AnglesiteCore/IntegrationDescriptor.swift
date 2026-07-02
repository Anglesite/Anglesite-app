public enum IntegrationID: String, Sendable, CaseIterable { case booking, contact, donations, giscus }

public struct Template: Sendable, Equatable, ExpressibleByStringLiteral {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public init(stringLiteral raw: String) { self.raw = raw }
    public func resolve(_ tokens: [String: String]) -> String {
        var out = raw
        for (key, value) in tokens {
            out = out.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return out
    }
}

public struct Choice: Sendable, Equatable { public let value: String; public let label: String
    public init(value: String, label: String) { self.value = value; self.label = label } }

public enum FieldKind: Sendable, Equatable {
    case text, email, url
    case choice([Choice])
    case bool
}

public enum Condition: Sendable, Equatable {
    case always
    case providerIs(String)
    case fieldEquals(key: String, value: String)
    case fieldIn(key: String, values: [String])
}

public struct Field: Sendable, Equatable, Identifiable {
    public let key: String
    public let label: String
    public let kind: FieldKind
    public let isOptional: Bool
    public let defaultValue: String?
    public let help: String?
    public let visibleWhen: Condition
    public var id: String { key }
    public init(key: String, label: String, kind: FieldKind, isOptional: Bool = false,
                defaultValue: String? = nil, help: String? = nil, visibleWhen: Condition = .always) {
        self.key = key; self.label = label; self.kind = kind; self.isOptional = isOptional
        self.defaultValue = defaultValue; self.help = help; self.visibleWhen = visibleWhen
    }
}

public struct Provider: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let cspDomains: [String]
    public init(id: String, displayName: String, cspDomains: [String]) {
        self.id = id; self.displayName = displayName; self.cspDomains = cspDomains
    }
}

public struct ConfigEntry: Sendable, Equatable {
    public let key: String
    public let value: Template
    public init(key: String, value: Template) { self.key = key; self.value = value }
}

/// A relative path under the website template root (Resources/Template/).
public struct TemplateRef: Sendable, Equatable { public let path: String
    public init(_ path: String) { self.path = path } }

public enum Operation: Sendable, Equatable {
    case copyFile(from: TemplateRef, to: Template, when: Condition)
    case writeConfig([ConfigEntry], when: Condition)
    case addCSPDomains(fromProvider: Bool, extra: [String], when: Condition)
    case injectAtAnchor(file: Template, anchor: String, snippet: Template, when: Condition, style: MarkerInjector.CommentStyle)
}

public struct IntegrationDescriptor: Sendable, Equatable, Identifiable {
    public let id: IntegrationID
    public let displayName: String
    public let summary: String
    public let providers: [Provider]
    public let fields: [Field]
    public let operations: [Operation]
    public init(id: IntegrationID, displayName: String, summary: String,
                providers: [Provider], fields: [Field], operations: [Operation]) {
        self.id = id; self.displayName = displayName; self.summary = summary
        self.providers = providers; self.fields = fields; self.operations = operations
    }
}
