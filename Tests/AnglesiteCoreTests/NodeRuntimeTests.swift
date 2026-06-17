import Testing
import Foundation
@testable import AnglesiteCore

struct NodeRuntimeTests {
    @Test("Prepends the directory to an existing PATH")
    func prependsToExistingPath() {
        let env = NodeRuntime.environment(["PATH": "/usr/bin:/bin"], prependingPATH: "/node/bin")
        #expect(env["PATH"] == "/node/bin:/usr/bin:/bin")
    }

    @Test("Sets PATH to just the directory when none exists")
    func setsPathWhenAbsent() {
        let env = NodeRuntime.environment([:], prependingPATH: "/node/bin")
        #expect(env["PATH"] == "/node/bin")
    }

    @Test("Treats an empty PATH as absent")
    func emptyPathBecomesDirectory() {
        let env = NodeRuntime.environment(["PATH": ""], prependingPATH: "/node/bin")
        #expect(env["PATH"] == "/node/bin")
    }

    @Test("Moves the directory to the front without duplicating when already present")
    func dedupesExistingEntry() {
        let env = NodeRuntime.environment(["PATH": "/usr/bin:/node/bin:/bin"], prependingPATH: "/node/bin")
        #expect(env["PATH"] == "/node/bin:/usr/bin:/bin")
    }

    @Test("Preserves other environment variables")
    func preservesOtherVariables() {
        let env = NodeRuntime.environment(["PATH": "/bin", "HOME": "/Users/x"], prependingPATH: "/node/bin")
        #expect(env["HOME"] == "/Users/x")
        #expect(env["PATH"] == "/node/bin:/bin")
    }
}
