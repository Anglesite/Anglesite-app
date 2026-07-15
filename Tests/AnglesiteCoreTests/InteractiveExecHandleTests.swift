import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct InteractiveExecHandleTests {
    @Test func writeAndTerminateInvokeInjectedHandlers() async throws {
        actor Recorder {
            private(set) var written: [Data] = []
            private(set) var terminated = false
            func recordWrite(_ data: Data) { written.append(data) }
            func recordTerminate() { terminated = true }
        }
        let recorder = Recorder()
        let handle = InteractiveExecHandle(
            write: { data in await recorder.recordWrite(data) },
            terminate: { await recorder.recordTerminate() }
        )
        try await handle.write(Data("hello".utf8))
        await handle.terminate()
        let written = await recorder.written
        let terminated = await recorder.terminated
        #expect(written == [Data("hello".utf8)])
        #expect(terminated)
    }
}
