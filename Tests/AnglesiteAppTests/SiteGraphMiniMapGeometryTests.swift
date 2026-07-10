import Testing
import Foundation
@testable import AnglesiteAppCore

@Suite("SiteGraphMiniMapGeometry")
struct SiteGraphMiniMapGeometryTests {
    @Test("mini-map is hidden at or below the node-count threshold and shown above it")
    func thresholdBoundary() {
        let threshold = SiteGraphMiniMapGeometry.nodeCountThreshold
        #expect(SiteGraphMiniMapGeometry.shouldShow(nodeCount: 0) == false)
        #expect(SiteGraphMiniMapGeometry.shouldShow(nodeCount: threshold) == false)
        #expect(SiteGraphMiniMapGeometry.shouldShow(nodeCount: threshold + 1) == true)
    }

    @Test("scaledPoint maps a canvas point proportionally into the mini-map rect")
    func scaledPointProportional() {
        let scaled = SiteGraphMiniMapGeometry.scaledPoint(
            CGPoint(x: 200, y: 100),
            from: CGSize(width: 800, height: 400),
            to: CGSize(width: 160, height: 100)
        )
        #expect(scaled == CGPoint(x: 40, y: 25))
    }

    @Test("scaledPoint degrades to .zero instead of dividing by a zero source dimension")
    func scaledPointZeroSource() {
        let scaled = SiteGraphMiniMapGeometry.scaledPoint(
            CGPoint(x: 200, y: 100),
            from: .zero,
            to: CGSize(width: 160, height: 100)
        )
        #expect(scaled == .zero)
    }

    @Test("nearestNodeID returns nil when there are no positions")
    func nearestNodeEmpty() {
        #expect(SiteGraphMiniMapGeometry.nearestNodeID(to: CGPoint(x: 10, y: 10), positions: [:]) == nil)
    }

    @Test("nearestNodeID picks the closest node to the tap point")
    func nearestNodePicksClosest() {
        let positions: [String: CGPoint] = [
            "far": CGPoint(x: 100, y: 100),
            "near": CGPoint(x: 12, y: 9),
            "middle": CGPoint(x: 50, y: 50),
        ]
        #expect(SiteGraphMiniMapGeometry.nearestNodeID(to: CGPoint(x: 10, y: 10), positions: positions) == "near")
    }

    @Test("nearestNodeID misses when the closest node is beyond maxDistance")
    func nearestNodeRespectsMaxDistance() {
        let positions = ["only": CGPoint(x: 100, y: 100)]
        #expect(SiteGraphMiniMapGeometry.nearestNodeID(to: .zero, positions: positions, maxDistance: 20) == nil)
        #expect(SiteGraphMiniMapGeometry.nearestNodeID(to: CGPoint(x: 90, y: 100), positions: positions, maxDistance: 20) == "only")
    }

    @Test("nearestNodeID breaks exact-distance ties deterministically by node ID")
    func nearestNodeTieBreak() {
        let positions: [String: CGPoint] = [
            "b": CGPoint(x: 20, y: 10),
            "a": CGPoint(x: 0, y: 10),
        ]
        // Both are exactly 10 points from the tap; the lexicographically smaller ID wins.
        #expect(SiteGraphMiniMapGeometry.nearestNodeID(to: CGPoint(x: 10, y: 10), positions: positions) == "a")
    }
}
