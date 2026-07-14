import Testing
import Foundation
@testable import AnglesiteCore

struct PreviewZoomTests {
    @Test("zooming in from actual size steps to the next detent")
    func zoomInFromActualSize() {
        #expect(PreviewZoom.zoomIn(from: 1.0) == 1.15)
    }

    @Test("zooming out from actual size steps to the previous detent")
    func zoomOutFromActualSize() {
        #expect(PreviewZoom.zoomOut(from: 1.0) == 0.85)
    }

    @Test("zoom in walks the detent ladder to the maximum")
    func zoomInLadder() {
        var level = PreviewZoom.actualSize
        var visited: [Double] = []
        while PreviewZoom.canZoomIn(from: level) {
            level = PreviewZoom.zoomIn(from: level)
            visited.append(level)
        }
        #expect(visited == [1.15, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0])
    }

    @Test("zoom out walks the detent ladder to the minimum")
    func zoomOutLadder() {
        var level = PreviewZoom.actualSize
        var visited: [Double] = []
        while PreviewZoom.canZoomOut(from: level) {
            level = PreviewZoom.zoomOut(from: level)
            visited.append(level)
        }
        #expect(visited == [0.85, 0.75, 0.5])
    }

    @Test("zoom in at the maximum stays clamped")
    func zoomInClampedAtMaximum() {
        #expect(PreviewZoom.zoomIn(from: PreviewZoom.maximum) == PreviewZoom.maximum)
        #expect(!PreviewZoom.canZoomIn(from: PreviewZoom.maximum))
    }

    @Test("zoom out at the minimum stays clamped")
    func zoomOutClampedAtMinimum() {
        #expect(PreviewZoom.zoomOut(from: PreviewZoom.minimum) == PreviewZoom.minimum)
        #expect(!PreviewZoom.canZoomOut(from: PreviewZoom.minimum))
    }

    @Test("an off-detent level snaps to the surrounding detents")
    func offDetentSnaps() {
        #expect(PreviewZoom.zoomIn(from: 1.1) == 1.15)
        #expect(PreviewZoom.zoomOut(from: 1.1) == 1.0)
    }

    @Test("a level beyond the ladder clamps back into range")
    func outOfRangeClamps() {
        #expect(PreviewZoom.zoomIn(from: 10.0) == PreviewZoom.maximum)
        #expect(PreviewZoom.zoomOut(from: 0.1) == PreviewZoom.minimum)
    }

    @Test("float noise near a detent does not double-step")
    func floatNoiseTolerated() {
        // 1.15 arrived at via repeated arithmetic can carry ulp noise; the next step up
        // must still be 1.25 (not 1.15 again) and the next step down 1.0.
        let noisy = 1.15 + 1e-9
        #expect(PreviewZoom.zoomIn(from: noisy) == 1.25)
        #expect(PreviewZoom.zoomOut(from: noisy) == 1.0)
    }

    @Test("actual size is a detent and the ladder bounds are sane")
    func ladderShape() {
        #expect(PreviewZoom.levels.contains(PreviewZoom.actualSize))
        #expect(PreviewZoom.levels == PreviewZoom.levels.sorted())
        #expect(PreviewZoom.minimum == 0.5)
        #expect(PreviewZoom.maximum == 3.0)
        #expect(PreviewZoom.canZoomIn(from: PreviewZoom.actualSize))
        #expect(PreviewZoom.canZoomOut(from: PreviewZoom.actualSize))
    }
}
