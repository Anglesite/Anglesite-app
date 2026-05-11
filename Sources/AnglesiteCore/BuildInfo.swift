import Foundation

public enum BuildInfo {
    public static let appName = "Anglesite"
    public static let phase = "0"

    public static var summary: String {
        "\(appName) · phase \(phase) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}
