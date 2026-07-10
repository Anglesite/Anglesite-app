import QuickLookThumbnailing

/// Real thumbnail-drawing logic lands in Task 5 of docs/superpowers/plans/2026-07-10-quicklook-extension.md.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        handler(nil, nil)
    }
}
