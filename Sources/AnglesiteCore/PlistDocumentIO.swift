import Foundation

/// Stateless IO for small property-list metadata files shown in the navigator.
/// The first GUI editor version intentionally supports root dictionaries with scalar values,
/// which covers package `Info.plist` and `Config/settings.plist`.
public enum PlistDocumentIO {
    public struct Loaded: Sendable, Equatable {
        public let entries: [PlistEntry]
        public let modificationDate: Date?
    }

    public struct PlistEntry: Sendable, Equatable, Identifiable {
        public var id: String { key }
        public var key: String
        public var value: PlistValue

        public init(key: String, value: PlistValue) {
            self.key = key
            self.value = value
        }
    }

    public enum PlistValue: Sendable, Equatable {
        case string(String)
        case bool(Bool)
        case integer(Int)
        case double(Double)
        case date(Date)
        case unsupported(String)

        public var kind: PlistValueKind {
            switch self {
            case .string: return .string
            case .bool: return .bool
            case .integer: return .integer
            case .double: return .double
            case .date: return .date
            case .unsupported: return .unsupported
            }
        }
    }

    public enum PlistValueKind: String, Sendable, CaseIterable, Identifiable {
        case string
        case bool
        case integer
        case double
        case date
        case unsupported

        public var id: String { rawValue }
    }

    public enum PlistError: Error, Sendable, Equatable {
        case rootNotDictionary
        case duplicateKey(String)
        case blankKey
        case unsupportedValue(key: String, description: String)
    }

    public static func load(_ url: URL, fileManager: FileManager = .default) throws -> Loaded {
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = object as? [String: Any] else {
            throw PlistError.rootNotDictionary
        }
        let entries = dictionary.keys.sorted().map { key in
            PlistEntry(key: key, value: value(from: dictionary[key] as Any))
        }
        return Loaded(entries: entries, modificationDate: try modificationDate(of: url, fileManager: fileManager))
    }

    @discardableResult
    public static func save(_ entries: [PlistEntry], to url: URL, fileManager: FileManager = .default) throws -> Date? {
        var dictionary: [String: Any] = [:]
        for entry in entries {
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw PlistError.blankKey }
            guard dictionary[key] == nil else { throw PlistError.duplicateKey(key) }
            dictionary[key] = try serializedValue(entry.value, key: key)
        }
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try data.write(to: url, options: [.atomic])
        return try modificationDate(of: url, fileManager: fileManager)
    }

    public static func externalChange(
        at url: URL,
        lastKnownModificationDate: Date?,
        bufferIsDirty: Bool,
        fileManager: FileManager = .default
    ) throws -> FileDocumentIO.ExternalChange {
        let current = try modificationDate(of: url, fileManager: fileManager)
        guard let current, let last = lastKnownModificationDate, current > last else {
            return .none
        }
        let diskContents = try String(contentsOf: url, encoding: .utf8)
        return bufferIsDirty ? .conflict(diskContents) : .reloadable(diskContents)
    }

    private static func value(from object: Any) -> PlistValue {
        switch object {
        case let value as String:
            return .string(value)
        case let value as Date:
            return .date(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            let type = String(cString: value.objCType)
            if ["f", "d"].contains(type) {
                return .double(value.doubleValue)
            }
            return .integer(value.intValue)
        case is [Any]:
            return .unsupported("Array")
        case is [String: Any]:
            return .unsupported("Dictionary")
        case is Data:
            return .unsupported("Data")
        default:
            return .unsupported(String(describing: type(of: object)))
        }
    }

    private static func serializedValue(_ value: PlistValue, key: String) throws -> Any {
        switch value {
        case .string(let string):
            return string
        case .bool(let bool):
            return bool
        case .integer(let int):
            return int
        case .double(let double):
            return double
        case .date(let date):
            return date
        case .unsupported(let description):
            throw PlistError.unsupportedValue(key: key, description: description)
        }
    }

    private static func modificationDate(of url: URL, fileManager: FileManager) throws -> Date? {
        try fileManager.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date
    }
}

extension PlistDocumentIO.PlistError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .rootNotDictionary:
            return "Only dictionary property lists can be edited here."
        case .duplicateKey(let key):
            return "The key \(key) appears more than once."
        case .blankKey:
            return "Keys can't be blank."
        case .unsupportedValue(let key, let description):
            return "\(key) is a \(description.lowercased()) value, which this editor can't save yet."
        }
    }
}
