import UniformTypeIdentifiers

public extension UTType {
    /// The `.anglesite` site package type the app exports (declared in both targets' Info.plist as
    /// `io.dwk.anglesite.site`).
    ///
    /// Uses `exportedAs:` (non-failable) rather than `UTType("io.dwk.anglesite.site")` (failable):
    /// the failable initializer returns `nil` when the UTI hasn't been registered in the current
    /// process — which includes `swift test`/CI contexts — and a `nil` slipped into
    /// `NSOpenPanel.allowedContentTypes` silently makes the panel accept every file type. All
    /// call sites should use `.anglesiteSite`.
    static let anglesiteSite = UTType(exportedAs: "io.dwk.anglesite.site")
}
