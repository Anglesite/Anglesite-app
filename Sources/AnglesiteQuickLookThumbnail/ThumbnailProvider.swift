import QuickLookThumbnailing
import AppKit
import AnglesiteSiteModel

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let package = AnglesitePackage(url: request.fileURL)
        guard let marker = try? package.readMarker() else {
            // Missing/corrupt marker: fall back to Quick Look's default folder icon rather than
            // drawing a misleading placeholder for something that isn't a readable site.
            handler(nil, nil)
            return
        }

        if FileManager.default.fileExists(atPath: package.quickLookThumbnailURL.path) {
            handler(QLThumbnailReply(imageFileURL: package.quickLookThumbnailURL), nil)
            return
        }

        let displayName = marker.displayName
        let reply = QLThumbnailReply(contextSize: request.maximumSize) {
            Self.drawMonogram(for: displayName, size: request.maximumSize)
            return true
        }
        handler(reply, nil)
    }

    /// Draws a rounded-rect badge with the site's first-letter monogram — the fallback shown
    /// until a real cached home-page thumbnail (`Config/quicklook-thumbnail.png`) exists.
    private static func drawMonogram(for displayName: String, size: CGSize) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = CGRect(origin: .zero, size: size)
        let inset = min(size.width, size.height) * 0.05
        let cornerRadius = min(size.width, size.height) * 0.12

        let backgroundPath = CGPath(
            roundedRect: rect.insetBy(dx: inset, dy: inset),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.addPath(backgroundPath)
        context.fillPath()

        let monogram = String(displayName.prefix(1)).uppercased()
        guard !monogram.isEmpty else { return }
        let fontSize = size.height * 0.4
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let attributedString = NSAttributedString(string: monogram, attributes: attributes)
        let textSize = attributedString.size()
        let textOrigin = CGPoint(
            x: rect.midX - textSize.width / 2,
            y: rect.midY - textSize.height / 2
        )
        attributedString.draw(at: textOrigin)
    }
}
