import XCTest
@testable import AnglesiteCore

final class LogCenterTests: XCTestCase {
    func testAppendRetainsLinesInOrder() async {
        let center = LogCenter()
        await center.append(source: "astro", stream: .stdout, text: "first")
        await center.append(source: "astro", stream: .stderr, text: "second")
        let snapshot = await center.snapshot()
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot.map(\.text), ["first", "second"])
        XCTAssertEqual(snapshot.map(\.stream), [.stdout, .stderr])
        XCTAssertEqual(snapshot.map(\.id), [0, 1])
    }

    func testRingBufferEvictsOldestLines() async {
        let center = LogCenter(bufferCapacity: 3)
        for i in 0..<5 {
            await center.append(source: "x", stream: .stdout, text: "line\(i)")
        }
        let snapshot = await center.snapshot()
        XCTAssertEqual(snapshot.map(\.text), ["line2", "line3", "line4"])
        // IDs are monotonic regardless of eviction — they're a global sequence, not an index.
        XCTAssertEqual(snapshot.map(\.id), [2, 3, 4])
    }

    func testSubscriberReceivesSubsequentAppends() async {
        let center = LogCenter()
        let sub = await center.subscribe()
        await center.append(source: "a", stream: .stdout, text: "one")
        await center.append(source: "b", stream: .stderr, text: "two")

        var collected: [String] = []
        var iterator = sub.stream.makeAsyncIterator()
        for _ in 0..<2 {
            guard let line = await iterator.next() else { break }
            collected.append(line.text)
        }
        XCTAssertEqual(collected, ["one", "two"])
    }

    func testMultipleSubscribersEachReceiveEveryLine() async {
        let center = LogCenter()
        let a = await center.subscribe()
        let b = await center.subscribe()
        let initialCount = await center.subscriberCount()
        XCTAssertEqual(initialCount, 2)

        await center.append(source: "s", stream: .stdout, text: "hello")

        var aIter = a.stream.makeAsyncIterator()
        var bIter = b.stream.makeAsyncIterator()
        let aLine = await aIter.next()
        let bLine = await bIter.next()
        XCTAssertEqual(aLine?.text, "hello")
        XCTAssertEqual(bLine?.text, "hello")
    }

    func testCancelEndsIterationAndUnregisters() async {
        let center = LogCenter()
        let sub = await center.subscribe()
        let initial = await center.subscriberCount()
        XCTAssertEqual(initial, 1)

        sub.cancel()
        // onTermination → removeSubscriber hops through a Task; allow it to land.
        var finalCount = await center.subscriberCount()
        for _ in 0..<20 where finalCount > 0 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            finalCount = await center.subscriberCount()
        }
        XCTAssertEqual(finalCount, 0)

        var iterator = sub.stream.makeAsyncIterator()
        let next = await iterator.next()
        XCTAssertNil(next)
    }
}
