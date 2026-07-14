import Foundation
import Testing
@testable import AnglesiteContainer
import AnglesiteCore

struct StaleExt4ArtifactTests {
    final class CapturedLines: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ line: String) {
            lock.withLock {
                storage.append(line)
            }
        }

        func contains(_ match: (String) -> Bool) -> Bool {
            lock.withLock {
                storage.contains(where: match)
            }
        }
    }

    @Test("stale ext4 artifact is removed before unpack")
    func removesStaleArtifact() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("anglesite-stale-ext4-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let artifact = dir.appendingPathComponent("rootfs-site.ext4")
        try Data("stale".utf8).write(to: artifact)

        let lines = CapturedLines()
        try ContainerizationControl.removeStaleExt4Artifact(
            at: artifact,
            label: "rootfs",
            onOutput: { line, _ in lines.append(line) })

        #expect(!fm.fileExists(atPath: artifact.path))
        #expect(lines.contains { $0.contains("removing stale rootfs ext4 artifact at \(artifact.path)") })
    }

    @Test("stale ext4 cleanup failure names the artifact path")
    func cleanupFailureNamesArtifactPath() throws {
        let artifact = URL(fileURLWithPath: "/tmp/rootfs-stale.ext4")
        let failure = CocoaError(.fileWriteUnknown)
        let lines = CapturedLines()

        do {
            try ContainerizationControl.removeStaleExt4Artifact(
                at: artifact,
                label: "rootfs",
                fileExists: { _ in true },
                removeItem: { _ in throw failure },
                onOutput: { line, _ in lines.append(line) }
            )
            Issue.record("expected stale artifact cleanup to fail")
        } catch LocalContainerError.imageUnavailable(let message) {
            #expect(message.contains("could not remove stale rootfs ext4 artifact at \(artifact.path)"))
            #expect(lines.contains { $0.contains("could not remove stale rootfs ext4 artifact at \(artifact.path)") })
        } catch {
            Issue.record("expected imageUnavailable, got \(error)")
        }
    }

    @Test("stale ext4 cleanup fails if the path survives removal")
    func cleanupFailsWhenArtifactSurvivesRemoval() throws {
        let artifact = URL(fileURLWithPath: "/tmp/initfs-stale.ext4")

        do {
            try ContainerizationControl.removeStaleExt4Artifact(
                at: artifact,
                label: "initfs",
                fileExists: { _ in true },
                removeItem: { _ in }
            )
            Issue.record("expected stale artifact cleanup to fail")
        } catch LocalContainerError.imageUnavailable(let message) {
            #expect(message == "stale initfs ext4 artifact still exists after removal at \(artifact.path)")
        } catch {
            Issue.record("expected imageUnavailable, got \(error)")
        }
    }
}
