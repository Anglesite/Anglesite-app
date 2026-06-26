import AppKit
import Foundation
import UniformTypeIdentifiers
import AnglesiteCore

enum WebsiteIconInstaller {
    static let allowedContentTypes: [UTType] = [.image]

    struct Result: Equatable {
        let wroteIconCount: Int
        let patchedLayout: Bool
    }

    enum InstallError: LocalizedError {
        case unreadableImage(URL)
        case pngEncodingFailed(Int)
        case icoTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .unreadableImage(let url):
                "Could not read the selected image at \(url.lastPathComponent)."
            case .pngEncodingFailed(let size):
                "Could not create the \(size)x\(size) website icon."
            case .icoTooLarge(let byteCount):
                "The generated favicon is too large (\(byteCount) bytes)."
            }
        }
    }

    static func install(from imageURL: URL, siteName: String, siteDirectory: URL,
                        fileManager: FileManager = .default) throws -> Result {
        guard let image = NSImage(contentsOf: imageURL), image.isValid else {
            throw InstallError.unreadableImage(imageURL)
        }

        let publicDir = siteDirectory.appendingPathComponent(WebsiteIconAsset.publicDirectoryRelativePath, isDirectory: true)
        try fileManager.createDirectory(at: publicDir, withIntermediateDirectories: true)

        let faviconPNG = try pngData(from: image, sideLength: 32)
        let generated: [(String, Data)] = [
            (WebsiteIconAsset.faviconICOName, try icoData(pngData: faviconPNG)),
            (WebsiteIconAsset.faviconPNGName, faviconPNG),
            (WebsiteIconAsset.appleTouchIconName, try pngData(from: image, sideLength: 180)),
            (WebsiteIconAsset.icon192Name, try pngData(from: image, sideLength: 192)),
            (WebsiteIconAsset.icon512Name, try pngData(from: image, sideLength: 512)),
            (WebsiteIconAsset.manifestName, try WebsiteIconAsset.manifestData(siteName: siteName))
        ]

        for (name, data) in generated {
            try data.write(to: publicDir.appendingPathComponent(name), options: .atomic)
        }

        let layoutURL = siteDirectory.appendingPathComponent(WebsiteIconAsset.layoutRelativePath)
        let before = try? String(contentsOf: layoutURL, encoding: .utf8)
        try WebsiteIconAsset.patchLayout(in: siteDirectory, fileManager: fileManager)
        let after = try? String(contentsOf: layoutURL, encoding: .utf8)

        return Result(wroteIconCount: generated.count, patchedLayout: before != after)
    }

    static func hasInstalledIcons(in siteDirectory: URL, fileManager: FileManager = .default) -> Bool {
        WebsiteIconAsset.hasInstalledIcons(in: siteDirectory, fileManager: fileManager)
    }

    private static func pngData(from image: NSImage, sideLength: Int) throws -> Data {
        let side = CGFloat(sideLength)
        let size = NSSize(width: side, height: side)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: sideLength,
            pixelsHigh: sideLength,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw InstallError.pngEncodingFailed(sideLength)
        }

        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: fittedRect(for: image.size, inside: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver,
                   fraction: 1)
        context?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw InstallError.pngEncodingFailed(sideLength)
        }
        return data
    }

    private static func fittedRect(for sourceSize: NSSize, inside targetSize: NSSize) -> NSRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return NSRect(origin: .zero, size: targetSize)
        }
        let scale = min(targetSize.width / sourceSize.width, targetSize.height / sourceSize.height)
        let fitted = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return NSRect(
            x: (targetSize.width - fitted.width) / 2,
            y: (targetSize.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private static func icoData(pngData: Data) throws -> Data {
        guard pngData.count <= Int(UInt32.max) else {
            throw InstallError.icoTooLarge(pngData.count)
        }

        var data = Data()
        appendUInt16(0, to: &data)      // reserved
        appendUInt16(1, to: &data)      // image type: icon
        appendUInt16(1, to: &data)      // image count
        data.append(32)                 // width
        data.append(32)                 // height
        data.append(0)                  // color count
        data.append(0)                  // reserved
        appendUInt16(1, to: &data)      // color planes
        appendUInt16(32, to: &data)     // bits per pixel
        appendUInt32(UInt32(pngData.count), to: &data)
        appendUInt32(22, to: &data)     // header + one directory entry
        data.append(pngData)
        return data
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }
}
