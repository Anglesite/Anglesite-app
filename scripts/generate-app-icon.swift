#!/usr/bin/env swift
//
// Generate the macOS AppIcon PNG set (#55).
//
// Draws the Anglesite "</>" mark — a left angle bracket and right angle bracket in the
// text color flanking a slash in the primary color — on a light squircle, at every size
// macOS needs. The geometry is the website logo's SVG (viewBox 0 0 32 32, stroke-width 3,
// round caps/joins) mapped into each icon canvas.
//
// When finished artwork exists, pass a 1024×1024 PNG and it is downscaled into the same
// slots instead of redrawing the mark:
//
//   scripts/generate-app-icon.swift                   # draw the </> logo
//   scripts/generate-app-icon.swift path/to/1024.png  # use a finished PNG
//
// Writes icon_<pt>x<pt>[@2x].png into Resources/Assets.xcassets/AppIcon.appiconset/
// to match the filenames in that set's Contents.json.

import AppKit
import Foundation

// (filename, pixel dimension) — the 10 mac slots: 16/32/128/256/512 @ 1x and 2x.
let slots: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

// Brand colors. brackets = --color-text, slash = --color-primary (adjust here to match the
// site's tokens exactly). Background is a near-white squircle so the dark mark reads as the
// web logo does on a light theme.
let bracketColor = NSColor(srgbRed: 0.114, green: 0.141, blue: 0.200, alpha: 1) // #1d2433 slate
let slashColor   = NSColor(srgbRed: 0.145, green: 0.388, blue: 0.922, alpha: 1) // #2563eb blue
let bgTop        = NSColor(srgbRed: 0.984, green: 0.988, blue: 0.996, alpha: 1) // #fbfcfe
let bgBottom     = NSColor(srgbRed: 0.925, green: 0.941, blue: 0.961, alpha: 1) // #ecf0f5
let borderColor  = NSColor(srgbRed: 0.847, green: 0.875, blue: 0.910, alpha: 1) // #d8dfe8 hairline

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let outDir = repoRoot
    .appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

// Optional source artwork (downscaled instead of drawing the mark).
let sourceImage: NSImage? = CommandLine.arguments.count > 1
    ? NSImage(contentsOfFile: CommandLine.arguments[1])
    : nil
if CommandLine.arguments.count > 1, sourceImage == nil {
    FileHandle.standardError.write("error: could not load source image \(CommandLine.arguments[1])\n".data(using: .utf8)!)
    exit(1)
}

/// Draw the "</>" logo on a light squircle.
func drawLogo(into rep: NSBitmapImageRep, px: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icons leave a margin around the art; inset ~9.4% so the rect reads as an app icon.
    let inset = px * 0.094
    let rect = NSRect(x: inset, y: inset, width: px - 2 * inset, height: px - 2 * inset)
    let radius = rect.width * 0.224 // Apple's continuous-corner squircle is ~22.4% of the side.
    let body = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(colors: [bgBottom, bgTop])?.draw(in: body, angle: 90)
    borderColor.setStroke()
    body.lineWidth = max(1, px * 0.004)
    body.stroke()

    // Map the 32-unit SVG viewBox into a centered square, flipping y (SVG is top-down,
    // AppKit is bottom-up).
    let markSize = px * 0.56
    let scale = markSize / 32.0
    let offset = (px - markSize) / 2.0
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: offset + x * scale, y: offset + (32 - y) * scale)
    }
    func stroke(_ points: [NSPoint], color: NSColor) {
        let path = NSBezierPath()
        path.lineWidth = 3 * scale          // stroke-width="3" in viewBox units
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: points[0])
        for pt in points.dropFirst() { path.line(to: pt) }
        color.setStroke()
        path.stroke()
    }

    stroke([p(12, 6), p(4, 16), p(12, 26)], color: bracketColor)  // <
    stroke([p(18, 6), p(14, 26)], color: slashColor)              // /
    stroke([p(20, 6), p(28, 16), p(20, 26)], color: bracketColor) // >

    NSGraphicsContext.restoreGraphicsState()
}

/// Downscale finished artwork into the bitmap rep.
func drawSource(_ image: NSImage, into rep: NSBitmapImageRep, px: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
               from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
}

for slot in slots {
    let px = CGFloat(slot.px)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: slot.px, pixelsHigh: slot.px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        FileHandle.standardError.write("error: could not allocate \(slot.px)px bitmap\n".data(using: .utf8)!)
        exit(1)
    }
    rep.size = NSSize(width: px, height: px)

    if let source = sourceImage {
        drawSource(source, into: rep, px: px)
    } else {
        drawLogo(into: rep, px: px)
    }

    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("error: PNG encode failed for \(slot.name)\n".data(using: .utf8)!)
        exit(1)
    }
    let dest = outDir.appendingPathComponent(slot.name)
    try! png.write(to: dest)
    print("  \(slot.name) (\(slot.px)×\(slot.px))")
}

print("Wrote \(slots.count) icons to \(outDir.path)")
