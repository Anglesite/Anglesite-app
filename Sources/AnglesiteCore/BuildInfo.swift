import Foundation

public enum BuildInfo {
    public static let appName = "Anglesite"
    // Bump manually at each phase milestone (tracked in docs/build-plan.md).
    public static let phase = "10"

    public static var summary: String {
        "\(appName) · phase \(phase) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}
