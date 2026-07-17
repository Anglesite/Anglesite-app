import Foundation

/// Canvas viewport-width presets for the Component Editor (design spec §3/§4.2): fixed device
/// widths for responsive work, pairing with media-query editing in the Styles panel
/// (`ComponentStyleGrouping`). Pure/testable — `ComponentEditorView` maps each case to an SF
/// Symbol and applies `.width` as a `.frame` constraint on the harness `WKWebView`.
public enum ComponentViewportPreset: String, CaseIterable, Identifiable, Sendable {
    case mobile, tablet, desktop, fill

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .mobile: "Mobile"
        case .tablet: "Tablet"
        case .desktop: "Desktop"
        case .fill: "Fill"
        }
    }

    public var systemImage: String {
        switch self {
        case .mobile: "iphone"
        case .tablet: "ipad"
        case .desktop: "display"
        case .fill: "arrow.up.left.and.arrow.down.right"
        }
    }

    /// Fixed viewport width in points, or `nil` for "Fill" (canvas fills the available pane width).
    public var width: Double? {
        switch self {
        case .mobile: 375
        case .tablet: 768
        case .desktop: 1440
        case .fill: nil
        }
    }
}
