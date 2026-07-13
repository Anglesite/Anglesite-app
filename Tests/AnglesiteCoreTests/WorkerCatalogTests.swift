import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WorkerDescriptor")
struct WorkerDescriptorTests {
    @Test("round-trips a componentTied worker through JSONEncoder/JSONDecoder")
    func roundTripsComponentTied() throws {
        let worker = WorkerDescriptor(
            id: "webmention",
            displayName: "Webmentions",
            description: "Receive and verify webmentions for posts",
            group: "social",
            binding: .componentTied(componentIDs: ["webmention-form"]),
            resources: WorkerDescriptor.Resources(needsD1: true, needsKV: true, needsR2: false)
        )

        let data = try JSONEncoder().encode(worker)
        let decoded = try JSONDecoder().decode(WorkerDescriptor.self, from: data)

        #expect(decoded == worker)
        #expect(decoded.binding == .componentTied(componentIDs: ["webmention-form"]))
    }

    @Test("round-trips a settingsActivated worker with no componentIDs")
    func roundTripsSettingsActivated() throws {
        let worker = WorkerDescriptor(
            id: "solid-pod",
            displayName: "Solid Pod",
            description: "Expose a Solid-compatible personal data store for this site",
            group: "storage",
            binding: .settingsActivated,
            resources: WorkerDescriptor.Resources(needsD1: false, needsKV: true, needsR2: true)
        )

        let data = try JSONEncoder().encode(worker)
        let decoded = try JSONDecoder().decode(WorkerDescriptor.self, from: data)

        #expect(decoded == worker)
        #expect(decoded.binding == .settingsActivated)
    }

    @Test("decoding an unknown binding kind throws")
    func unknownBindingKindThrows() {
        let json = """
        { "kind": "somethingElse" }
        """.data(using: .utf8)!

        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(WorkerDescriptor.Binding.self, from: json)
        }
    }
}
