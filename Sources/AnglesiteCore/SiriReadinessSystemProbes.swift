import Foundation
#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels
#endif

/// Confirms the running OS meets Anglesite's macOS floor. Version is injectable so the
/// mapping is testable without spoofing the process environment.
public struct OSRuntimeProbe: ReadinessProbe {
    public let id = "os.runtime"
    public let title = "macOS runtime"
    private let version: OperatingSystemVersion
    private let minimumMajor: Int

    public init(
        version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        minimumMajor: Int = 27
    ) {
        self.version = version
        self.minimumMajor = minimumMajor
    }

    public func check() async -> ReadinessFinding {
        let running = "\(version.majorVersion).\(version.minorVersion)"
        if version.majorVersion >= minimumMajor {
            return ReadinessFinding(id: id, title: title, level: .ok,
                detail: "macOS \(running) meets the macOS \(minimumMajor) requirement for Siri workflows.")
        }
        return ReadinessFinding(id: id, title: title, level: .failure,
            detail: "macOS \(running) is below the macOS \(minimumMajor) requirement.",
            remediation: "Update to macOS \(minimumMajor) or later in System Settings ▸ General ▸ Software Update.")
    }
}

/// Normalized Foundation Models availability, decoupled from the SDK enum so the probe
/// mapping is testable without the framework.
public enum FoundationModelsAvailability: Sendable, Equatable {
    case available
    case appleIntelligenceNotEnabled
    case modelNotReady
    case deviceNotEligible
    case unknown(String)
}

/// Reports whether Apple's on-device language model is usable. Availability is injected so
/// tests never touch the live model; the live source reads `SystemLanguageModel` (no inference).
public struct FoundationModelsProbe: ReadinessProbe {
    public let id = "foundation.models"
    public let title = "Apple Foundation Models"
    private let availability: @Sendable () -> FoundationModelsAvailability

    public init(availability: @escaping @Sendable () -> FoundationModelsAvailability) {
        self.availability = availability
    }

    public func check() async -> ReadinessFinding {
        switch availability() {
        case .available:
            return ReadinessFinding(id: id, title: title, level: .ok,
                detail: "The on-device language model is available for summarization and chat.")
        case .appleIntelligenceNotEnabled:
            return ReadinessFinding(id: id, title: title, level: .warning,
                detail: "Apple Intelligence is turned off.",
                remediation: "Enable Apple Intelligence in System Settings ▸ Apple Intelligence & Siri.")
        case .modelNotReady:
            return ReadinessFinding(id: id, title: title, level: .warning,
                detail: "The on-device model is still downloading or preparing.",
                remediation: "Wait for the model to finish downloading, then re-check.")
        case .deviceNotEligible:
            return ReadinessFinding(id: id, title: title, level: .unsupported,
                detail: "This Mac does not support Apple Foundation Models.")
        case .unknown(let reason):
            return ReadinessFinding(id: id, title: title, level: .warning,
                detail: "Foundation Models availability could not be determined: \(reason).")
        }
    }
}

/// Live availability source. Reads `SystemLanguageModel.default.availability` (no inference).
/// Case names below must match the `FoundationModels` SDK; `@unknown default` absorbs drift.
public enum LiveFoundationModelsAvailability {
    public static func current() -> FoundationModelsAvailability {
        #if compiler(>=6.4) && canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
            case .modelNotReady: return .modelNotReady
            case .deviceNotEligible: return .deviceNotEligible
            @unknown default: return .unknown("\(reason)")
            }
        @unknown default:
            return .unknown("unrecognized availability")
        }
        #else
        return .unknown("FoundationModels unavailable at build time")
        #endif
    }
}
