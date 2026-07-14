// SwiftUI is Darwin-only; this bridge exists purely for the (Darwin-only) Styles panel's
// ColorPicker, so it compiles out cleanly on the portable core (cross-platform port design §5).
#if canImport(SwiftUI)
import SwiftUI

/// Best-effort CSS <color> <-> SwiftUI Color bridge for the Styles panel's ColorPicker.
/// Only handles #rgb/#rrggbb/#rrggbbaa hex forms — named colors and rgb()/hsl() fall back
/// to the free-text field, which always remains available.
public enum CSSColor {
    public static func parse(_ value: String) -> Color? {
        var hex = value.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.count == 3 || hex.count == 6 || hex.count == 8 else { return nil }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard let value = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return Color(red: r, green: g, blue: b, opacity: a)
    }

    public static func format(_ color: Color) -> String {
        guard let cgColor = color.cgColor, let components = cgColor.components, components.count >= 3 else {
            return "#000000"
        }
        let r = Int((components[0] * 255).rounded())
        let g = Int((components[1] * 255).rounded())
        let b = Int((components[2] * 255).rounded())
        // `components` is [r, g, b, alpha] for RGB-family color spaces; `cgColor.alpha` is the
        // authoritative alpha regardless of component layout, so use it rather than indexing
        // components[3] (which would be wrong for e.g. a grayscale-backed CGColor).
        let alpha = cgColor.alpha
        guard alpha < 1 else { return String(format: "#%02x%02x%02x", r, g, b) }
        let a = Int((alpha * 255).rounded())
        return String(format: "#%02x%02x%02x%02x", r, g, b, a)
    }

    public static let colorProperties: Set<String> = [
        "color", "background-color", "border-color", "outline-color", "fill", "stroke",
        "border-top-color", "border-right-color", "border-bottom-color", "border-left-color",
    ]
}
#endif
