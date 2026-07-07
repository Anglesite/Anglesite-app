import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct DependencyBaselineTests {
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func returnsNilWhenNoBaselineFileExists() {
        #expect(DependencyBaseline.load(from: tmpDir()) == nil)
    }

    @Test func roundTripsThroughSaveAndLoad() throws {
        let dir = tmpDir()
        let packages = ["astro": "^6.4.8", "tsx": "^4.0.0"]
        try DependencyBaseline.save(packages, to: dir)
        #expect(DependencyBaseline.load(from: dir) == packages)
    }

    @Test func savingOverwritesAPreviousBaseline() throws {
        let dir = tmpDir()
        try DependencyBaseline.save(["astro": "^5.0.0"], to: dir)
        try DependencyBaseline.save(["astro": "^6.4.8"], to: dir)
        #expect(DependencyBaseline.load(from: dir) == ["astro": "^6.4.8"])
    }
}
