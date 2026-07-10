import Foundation

/// Pure geometry for the Site Graph mini-map (#613): threshold gating, canvas→mini-map point
/// scaling, and click-to-jump hit-testing. Kept UI-free so `AnglesiteAppTests` can cover it.
enum SiteGraphMiniMapGeometry {
    /// Below this many visible nodes the main canvas is legible on its own and a mini-map is
    /// redundant clutter, so it only appears *above* the threshold.
    static let nodeCountThreshold = 30

    static func shouldShow(nodeCount: Int) -> Bool {
        nodeCount > nodeCountThreshold
    }

    /// Maps a point in the main canvas' coordinate space proportionally into the mini-map's.
    /// A degenerate (zero-sized) source collapses to `.zero` rather than dividing by zero.
    static func scaledPoint(_ point: CGPoint, from source: CGSize, to target: CGSize) -> CGPoint {
        guard source.width > 0, source.height > 0 else { return .zero }
        return CGPoint(
            x: point.x / source.width * target.width,
            y: point.y / source.height * target.height
        )
    }

    /// The node whose position is closest to `point`, for click-to-jump selection. Exact-distance
    /// ties break lexicographically by ID so repeated clicks are deterministic.
    static func nearestNodeID(to point: CGPoint, positions: [String: CGPoint]) -> String? {
        positions.min { lhs, rhs in
            let lhsDistance = hypot(lhs.value.x - point.x, lhs.value.y - point.y)
            let rhsDistance = hypot(rhs.value.x - point.x, rhs.value.y - point.y)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs.key < rhs.key
        }?.key
    }
}
