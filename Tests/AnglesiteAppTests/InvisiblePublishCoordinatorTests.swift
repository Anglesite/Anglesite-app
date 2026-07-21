import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

/// `isPublishRelevant` is the one piece of `InvisiblePublishCoordinator` (#822, extracted from
/// `SiteWindowModel`) that's pure logic with no queue/watcher/actor state to stand up — a batch of
/// changed paths in, a bool out — so it gets direct coverage here rather than only being exercised
/// indirectly through a live file watcher.
@Suite("InvisiblePublishCoordinator.isPublishRelevant")
struct InvisiblePublishCoordinatorTests {
    private let root = URL(fileURLWithPath: "/tmp/site-root")

    @Test("a full-rescan batch is always relevant, even with no paths")
    func fullRescanIsAlwaysRelevant() {
        let batch = FileChangeBatch(paths: [], needsFullRescan: true)
        #expect(InvisiblePublishCoordinator.isPublishRelevant(batch, sourceDirectory: root))
    }

    @Test("a change under an ignored top-level directory (.git) is not relevant")
    func gitDirectoryIsIgnored() {
        let batch = FileChangeBatch(
            paths: [root.appendingPathComponent(".git/index")], needsFullRescan: false
        )
        #expect(!InvisiblePublishCoordinator.isPublishRelevant(batch, sourceDirectory: root))
    }

    @Test("a change under each other ignored top-level directory is not relevant")
    func otherIgnoredDirectoriesAreIgnored() {
        for ignored in [".astro", "dist", "node_modules"] {
            let batch = FileChangeBatch(
                paths: [root.appendingPathComponent("\(ignored)/generated.js")], needsFullRescan: false
            )
            #expect(
                !InvisiblePublishCoordinator.isPublishRelevant(batch, sourceDirectory: root),
                "expected \(ignored) to be filtered out"
            )
        }
    }

    @Test("a change under src/ is relevant")
    func sourceChangeIsRelevant() {
        let batch = FileChangeBatch(
            paths: [root.appendingPathComponent("src/pages/about.astro")], needsFullRescan: false
        )
        #expect(InvisiblePublishCoordinator.isPublishRelevant(batch, sourceDirectory: root))
    }

    @Test("a batch mixing an ignored path and a relevant path is relevant")
    func mixedBatchIsRelevantIfAnyPathQualifies() {
        let batch = FileChangeBatch(
            paths: [
                root.appendingPathComponent(".git/index"),
                root.appendingPathComponent("src/pages/about.astro"),
            ],
            needsFullRescan: false
        )
        #expect(InvisiblePublishCoordinator.isPublishRelevant(batch, sourceDirectory: root))
    }

    @Test("a change outside sourceDirectory entirely is not relevant")
    func pathOutsideRootIsNotRelevant() {
        let batch = FileChangeBatch(
            paths: [URL(fileURLWithPath: "/tmp/somewhere-else/file.txt")], needsFullRescan: false
        )
        #expect(!InvisiblePublishCoordinator.isPublishRelevant(batch, sourceDirectory: root))
    }

    @Test("a change directly at sourceDirectory's root (no relative component) is relevant")
    func changeAtRootIsRelevant() {
        let batch = FileChangeBatch(paths: [root], needsFullRescan: false)
        #expect(InvisiblePublishCoordinator.isPublishRelevant(batch, sourceDirectory: root))
    }
}
