import Foundation

/// Records which bundled OCI layout was last imported into the on-disk `ImageStore`, so the boot
/// path can tell "already imported this exact image" from "the app update shipped a new one" (#549).
///
/// The store's own `load(from:)` *does* repoint a tag on re-import, but importing on every boot is
/// wasteful — so `ContainerizationControl.loadOrGet` short-circuits to `get(reference:)` when the
/// store already has the reference. Without this marker that short-circuit is unconditional: the
/// first-ever imported image is served forever and image updates shipped by app updates never take
/// effect. Like `OCILayoutStaging`, the identity check is byte-equality of the layout's
/// `index.json` (it carries the manifest digests, so any image change changes it) — and the logic
/// lives here (pure Foundation, no Containerization dependency) so it stays covered by CI's
/// `swift test`, which never compiles the AnglesiteContainer module.
public enum OCILayoutImportMarker {
    /// True when the layout at `layout` is byte-identical (by `index.json`) to what
    /// `recordImported` last recorded for `name` — i.e. the store already holds this exact image
    /// and the import can be skipped. False on first boot, after an app update that ships a
    /// changed layout, or when either `index.json` is unreadable (fail toward re-importing).
    public static func isCurrent(layout: URL, name: String, storeRoot: URL) -> Bool {
        guard
            let recorded = try? Data(contentsOf: markerURL(name: name, storeRoot: storeRoot)),
            let current = try? Data(contentsOf: layout.appendingPathComponent("index.json"))
        else { return false }
        return recorded == current
    }

    /// Records that the layout at `layout` was just imported into the store for `name`.
    /// Call only after a successful `ImageStore.load(from:)` — recording first would let a failed
    /// import masquerade as current. The write is atomic, so a concurrent `isCurrent` reader sees
    /// either the old marker or the new one, never a torn file.
    public static func recordImported(layout: URL, name: String, storeRoot: URL) throws {
        let marker = markerURL(name: name, storeRoot: storeRoot)
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: layout.appendingPathComponent("index.json"))
            .write(to: marker, options: .atomic)
    }

    private static func markerURL(name: String, storeRoot: URL) -> URL {
        storeRoot.appendingPathComponent("imported-markers/\(name).index.json")
    }
}
