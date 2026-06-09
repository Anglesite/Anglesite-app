import Foundation

public enum BuildInfo {
    public static let appName = "Anglesite"
    public static let phase = "9"

    public static var summary: String {
        "\(appName) · phase \(phase) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}
