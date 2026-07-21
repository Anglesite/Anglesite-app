import Foundation

extension FileManager {
    /// Portable spelling of `homeDirectoryForCurrentUser`, which is compile-time unavailable on
    /// iOS. On iOS this resolves the app's sandboxed container home via `NSHomeDirectory()`
    /// (bypassing the receiver — no injected-`FileManager` test exercises the iOS leg); every
    /// other platform keeps the instance property so the DI seam callers rely on stays intact.
    public var portableHomeDirectory: URL {
        #if os(iOS)
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #else
        homeDirectoryForCurrentUser
        #endif
    }
}
