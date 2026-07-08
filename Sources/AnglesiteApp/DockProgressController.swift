import AppKit
import AnglesiteCore

/// Draws a progress bar over the Dock icon while a deploy runs (#526), via
/// `NSApp.dockTile.contentView` — the supported AppKit mechanism for custom Dock-tile drawing
/// (there is no public "NSProgress on the Dock" API on macOS).
///
/// Progress values arrive per *token* (one per site's running deploy) so two windows deploying
/// concurrently don't fight over the tile: the bar shows the least-complete run, and the overlay
/// only clears when every tracked operation has finished. Fractions come from
/// `DeployDockProgress` (unit-tested in AnglesiteCore); `nil` renders an indeterminate bar.
@MainActor
final class DockProgressController {
    static let shared = DockProgressController()

    /// Active operations: token → last known fraction (`nil` = indeterminate).
    private var active: [String: Double?] = [:]
    private let overlay = DockProgressOverlayView()

    /// Record progress for `token` and redraw the tile.
    func update(fraction: Double?, for token: String) {
        active[token] = fraction
        render()
    }

    /// The operation for `token` finished (any outcome); drop it and redraw/clear the tile.
    func clear(token: String) {
        guard active.removeValue(forKey: token) != nil else { return }
        render()
    }

    private func render() {
        let tile = NSApp.dockTile
        guard !active.isEmpty else {
            // Restore the plain app icon.
            tile.contentView = nil
            tile.display()
            return
        }
        // Any indeterminate run makes the bar indeterminate; otherwise show the least-complete
        // run so the bar never appears to finish while a deploy is still going.
        let fractions = active.values
        overlay.fraction = fractions.contains { $0 == nil } ? nil : fractions.compactMap { $0 }.min()
        if tile.contentView !== overlay {
            tile.contentView = overlay
        }
        tile.display()
    }
}

/// The Dock-tile content view: the app icon with a horizontal progress bar near the bottom,
/// in the style of Finder's copy/download badges. `fraction == nil` draws an indeterminate
/// (partial, centered) fill — the Dock tile only repaints on `display()`, so an animated
/// barber-pole would just be a frozen frame anyway.
private final class DockProgressOverlayView: NSView {
    var fraction: Double? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)

        let barHeight = bounds.height * 0.09
        let inset = bounds.width * 0.12
        let track = NSRect(
            x: inset,
            y: bounds.height * 0.08,
            width: bounds.width - inset * 2,
            height: barHeight
        )
        let radius = barHeight / 2

        // Track: mostly-opaque light capsule with a hairline border so it reads on any wallpaper.
        let trackPath = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
        NSColor.white.withAlphaComponent(0.85).setFill()
        trackPath.fill()
        NSColor.black.withAlphaComponent(0.35).setStroke()
        trackPath.lineWidth = 1
        trackPath.stroke()

        // Fill: determinate = leading portion; indeterminate = a centered 30% segment.
        let fillRect: NSRect
        if let fraction {
            let clamped = max(0, min(1, fraction))
            fillRect = NSRect(x: track.minX, y: track.minY, width: track.width * clamped, height: track.height)
        } else {
            let width = track.width * 0.3
            fillRect = NSRect(x: track.midX - width / 2, y: track.minY, width: width, height: track.height)
        }
        guard fillRect.width >= barHeight else { return }   // too small for the capsule; skip
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fillRect.insetBy(dx: 1, dy: 1), xRadius: radius - 1, yRadius: radius - 1).fill()
    }
}
