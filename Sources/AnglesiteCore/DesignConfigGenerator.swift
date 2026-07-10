import Foundation

public struct DesignTypography: Sendable, Equatable, Codable {
    public let display: String
    public let body: String
    public let pairing: String
    public init(display: String, body: String, pairing: String) { self.display = display; self.body = body; self.pairing = pairing }
}

public struct DesignSpacing: Sendable, Equatable, Codable {
    public let xs, sm, md, lg, xl: String
    public init(xs: String, sm: String, md: String, lg: String, xl: String) {
        self.xs = xs; self.sm = sm; self.md = md; self.lg = lg; self.xl = xl
    }
}

public struct DesignShape: Sendable, Equatable, Codable {
    public let radiusSm, radiusMd, radiusLg, shadowSm, shadowMd: String
    public init(radiusSm: String, radiusMd: String, radiusLg: String, shadowSm: String, shadowMd: String) {
        self.radiusSm = radiusSm; self.radiusMd = radiusMd; self.radiusLg = radiusLg
        self.shadowSm = shadowSm; self.shadowMd = shadowMd
    }
}

public struct DesignConfig: Sendable, Equatable, Codable {
    public let axes: DesignAxes
    public let palette: DesignPalette
    public let typography: DesignTypography
    public let spacing: DesignSpacing
    public let shape: DesignShape
    public let siteType: String
    public let brandColor: String?

    public init(axes: DesignAxes, palette: DesignPalette, typography: DesignTypography,
                spacing: DesignSpacing, shape: DesignShape, siteType: String, brandColor: String?) {
        self.axes = axes; self.palette = palette; self.typography = typography
        self.spacing = spacing; self.shape = shape; self.siteType = siteType; self.brandColor = brandColor
    }
}

public enum DesignConfigGenerator {
    private struct FontPairing {
        let display: String
        let body: String
        let pairing: String
        let score: (DesignAxes) -> Double
    }

    private static let fontPairings: [FontPairing] = [
        FontPairing(display: #"Georgia, "Times New Roman", Times, serif"#,
                    body: "system-ui, -apple-system, sans-serif",
                    pairing: "classic-serif+modern-sans",
                    score: { (1 - $0.time) * 2 + $0.register * 1.5 + (1 - $0.voice) * 0.5 }),
        FontPairing(display: "system-ui, -apple-system, sans-serif",
                    body: "system-ui, -apple-system, sans-serif",
                    pairing: "modern-sans+modern-sans",
                    score: { $0.time * 1.5 + (1 - $0.register) * 1 + $0.voice * 0.5 }),
        FontPairing(display: #""Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif"#,
                    body: #""Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif"#,
                    pairing: "humanist-sans+humanist-sans",
                    score: { $0.temperature * 1.5 + (1 - $0.register) * 1 + (1 - $0.voice) * 0.5 }),
        FontPairing(display: #"Georgia, "Times New Roman", Times, serif"#,
                    body: #""Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif"#,
                    pairing: "classic-serif+humanist-sans",
                    score: { (1 - $0.time) * 1.5 + $0.register * 1 + $0.temperature * 0.8 }),
        FontPairing(display: "system-ui, -apple-system, sans-serif",
                    body: #""Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif"#,
                    pairing: "modern-sans+humanist-sans",
                    score: { $0.time * 1 + $0.temperature * 0.8 + (1 - $0.register) * 0.8 }),
    ]

    public static func typography(for axes: DesignAxes) -> DesignTypography {
        let best = fontPairings.max { $0.score(axes) < $1.score(axes) } ?? fontPairings[0]
        return DesignTypography(display: best.display, body: best.body, pairing: best.pairing)
    }

    /// Airy (weight=0) -> generous spacing (1.2x). Dense (weight=1) -> tighter (0.8x).
    public static func spacing(for axes: DesignAxes) -> DesignSpacing {
        let m = 1.2 - axes.weight * 0.4
        func fmt(_ v: Double) -> String { "\((v * 1000).rounded() / 1000)rem" }
        return DesignSpacing(xs: fmt(0.25 * m), sm: fmt(0.5 * m), md: fmt(1 * m), lg: fmt(2 * m), xl: fmt(4 * m))
    }

    /// Playful (low register) + contemporary (high time) -> rounder. Bold (voice) -> stronger shadows.
    public static func shape(for axes: DesignAxes) -> DesignShape {
        let roundness = (1 - axes.register) * 0.6 + axes.time * 0.4
        func fmt(_ v: Double) -> String { "\((v * 1000).rounded() / 1000)rem" }
        let shadowAlpha = 0.06 + axes.voice * 0.08
        let shadowSpread = 2 + axes.weight * 4
        return DesignShape(
            radiusSm: fmt(0.125 + roundness * 0.25),
            radiusMd: fmt(0.25 + roundness * 0.5),
            radiusLg: fmt(0.5 + roundness * 1.0),
            shadowSm: "0 1px \(Int(shadowSpread.rounded()))px rgba(0, 0, 0, \(String(format: "%.2f", shadowAlpha)))",
            shadowMd: "0 \(Int(shadowSpread.rounded()))px \(Int((shadowSpread * 3).rounded()))px rgba(0, 0, 0, \(String(format: "%.2f", shadowAlpha * 1.5)))"
        )
    }

    public static func config(axes: DesignAxes, siteType: String, brandColor: String?) -> DesignConfig {
        DesignConfig(
            axes: axes,
            palette: DesignPaletteGenerator.generate(axes: axes, brandColor: brandColor),
            typography: typography(for: axes),
            spacing: spacing(for: axes),
            shape: shape(for: axes),
            siteType: siteType,
            brandColor: brandColor
        )
    }
}
