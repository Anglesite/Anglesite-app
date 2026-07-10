import Cocoa
import Quartz

/// Real preview logic lands in Task 4 of docs/superpowers/plans/2026-07-10-quicklook-extension.md.
final class PreviewViewController: NSViewController, QLPreviewingController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView()
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        handler(nil)
    }
}
