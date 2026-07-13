import Foundation

/// One `@dwk/workers` package as described by the monorepo's published catalog manifest
/// (`catalog.json`). Intentionally generic — this app never hardcodes specific worker names
/// (design doc §3): whatever the manifest lists is what the Workers tab shows and what deploy
/// composition can activate.
public struct WorkerDescriptor: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let displayName: String
    public let description: String
    /// Free-text grouping key the Workers tab sections by (e.g. `"social"`, `"storage"`) — never
    /// enumerated in Swift, since the manifest owns the set of groups.
    public let group: String
    public let binding: Binding
    public let resources: Resources

    public init(
        id: String,
        displayName: String,
        description: String,
        group: String,
        binding: Binding,
        resources: Resources
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.group = group
        self.binding = binding
        self.resources = resources
    }

    /// How a worker becomes active. `componentTied` workers are never manually toggled — their
    /// active state is always recomputed from Site Graph Explorer's `ImpactAnalysis` against
    /// `componentIDs` (design doc §4). `settingsActivated` workers are toggled in the Workers tab.
    public enum Binding: Sendable, Equatable, Codable {
        case componentTied(componentIDs: [String])
        case settingsActivated

        private enum CodingKeys: String, CodingKey {
            case kind
            case componentIDs
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(String.self, forKey: .kind)
            switch kind {
            case "componentTied":
                let componentIDs = try container.decode([String].self, forKey: .componentIDs)
                self = .componentTied(componentIDs: componentIDs)
            case "settingsActivated":
                self = .settingsActivated
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind, in: container, debugDescription: "unknown binding kind \"\(kind)\"")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .componentTied(let componentIDs):
                try container.encode("componentTied", forKey: .kind)
                try container.encode(componentIDs, forKey: .componentIDs)
            case .settingsActivated:
                try container.encode("settingsActivated", forKey: .kind)
            }
        }
    }

    /// Generalizes `WorkerComposition.Feature`'s hand-maintained `needsD1`/`needsKV`/`needsR2`
    /// switch statements (`WorkerComposition.swift:28-53`) into manifest-driven data.
    public struct Resources: Sendable, Equatable, Codable {
        public let needsD1: Bool
        public let needsKV: Bool
        public let needsR2: Bool

        public init(needsD1: Bool, needsKV: Bool, needsR2: Bool) {
            self.needsD1 = needsD1
            self.needsKV = needsKV
            self.needsR2 = needsR2
        }
    }
}
