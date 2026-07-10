import Cocoa
import Quartz
import SwiftUI
import AnglesiteSiteModel
import AnglesiteQuickLookSupport

final class PreviewViewController: NSViewController, QLPreviewingController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView()
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let package = AnglesitePackage(url: url)
        let summary = try? PackagePreviewSummary.summarize(package)

        let hosting = NSHostingController(rootView: PreviewContentView(summary: summary))
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.width, .height]
        view.addSubview(hosting.view)

        handler(nil)
    }
}
