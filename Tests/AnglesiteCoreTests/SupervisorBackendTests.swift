import XCTest
@testable import AnglesiteCore

final class SupervisorBackendTests: XCTestCase {
    func test_spawnSpec_codable_roundTrip() throws {
        let original = SpawnSpec(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["status", "--porcelain"],
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: URL(fileURLWithPath: "/tmp/site"),
            workingDirectoryBookmark: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            stdinPipe: true,
            logSource: "git:status"
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SpawnSpec.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    func test_spawnSpec_codable_nilFieldsRoundTrip() throws {
        let original = SpawnSpec(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hi"],
            environment: nil,
            workingDirectory: nil,
            workingDirectoryBookmark: nil,
            stdinPipe: false,
            logSource: "echo"
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SpawnSpec.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }
}
