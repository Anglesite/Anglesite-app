import XCTest
@testable import AnglesiteCore

final class GitHubAuthFlowTests: XCTestCase {

    // MARK: Parser

    func testParserExtractsCodeAndURLFromTwoSeparateLines() {
        var parser = GitHubAuthFlow.PromptParser()
        XCTAssertNil(parser.feed("! First copy your one-time code: ABCD-1234"))
        guard let event = parser.feed("Press Enter to open https://github.com/login/device in your browser...") else {
            return XCTFail("expected devicePrompt event after second line")
        }
        XCTAssertEqual(event, .devicePrompt(
            verificationURL: URL(string: "https://github.com/login/device")!,
            userCode: "ABCD-1234"
        ))
    }

    func testParserHandlesAlternativeLabelWording() {
        // gh has shipped "First copy your one-time code:" and "Copy your one-time code:" both.
        var parser = GitHubAuthFlow.PromptParser()
        XCTAssertNil(parser.feed("Copy your one-time code: WXYZ-9876"))
        XCTAssertNotNil(parser.feed("Open https://github.com/login/device"))
        XCTAssertEqual(parser.code, "WXYZ-9876")
    }

    func testParserStripsANSIEscapes() {
        // gh colorizes prompts in a TTY. Real output may include CSI sequences.
        var parser = GitHubAuthFlow.PromptParser()
        let coloredCode = "\u{001B}[1m! First copy your one-time code:\u{001B}[0m ABCD-1234"
        XCTAssertNil(parser.feed(coloredCode))
        let coloredURL = "Press Enter to open \u{001B}[4mhttps://github.com/login/device\u{001B}[0m in your browser..."
        guard let event = parser.feed(coloredURL) else { return XCTFail("expected event") }
        if case .devicePrompt(let url, let code) = event {
            XCTAssertEqual(code, "ABCD-1234")
            XCTAssertEqual(url.absoluteString, "https://github.com/login/device")
        } else {
            XCTFail("expected devicePrompt, got \(event)")
        }
    }

    func testParserStripsTrailingPunctuationFromURL() {
        // "...in your browser..." — three dots after the URL must not become part of it.
        var parser = GitHubAuthFlow.PromptParser()
        _ = parser.feed("one-time code: A1B2-C3D4")
        _ = parser.feed("Press Enter to open https://github.com/login/device... in your browser.")
        XCTAssertEqual(parser.verificationURL?.absoluteString, "https://github.com/login/device")
    }

    func testParserReturnsNilUntilBothPiecesSeen() {
        var parser = GitHubAuthFlow.PromptParser()
        XCTAssertNil(parser.feed("some unrelated stderr line"))
        XCTAssertNil(parser.feed("one-time code: ZZZZ-9999"))
        XCTAssertNil(parser.feed("still nothing"))
        XCTAssertNotNil(parser.feed("https://github.com/login/device"))
    }

    func testParserNormalizesCodeToUppercase() {
        var parser = GitHubAuthFlow.PromptParser()
        _ = parser.feed("one-time code: abcd-1234")
        XCTAssertEqual(parser.code, "ABCD-1234")
    }

    func testParserDoesNotPickUpUnrelatedGitHubURLs() {
        // gh's help text occasionally links to docs.github.com or github.com — must not match.
        var parser = GitHubAuthFlow.PromptParser()
        _ = parser.feed("one-time code: AAAA-BBBB")
        _ = parser.feed("See https://docs.github.com for help.")
        XCTAssertNil(parser.verificationURL, "non-device URLs must not be accepted")
        _ = parser.feed("Open https://github.com/login/device")
        XCTAssertNotNil(parser.verificationURL)
    }

    // MARK: Flow lifecycle (with fixture launcher)

    func testFlowYieldsPromptThenAuthenticatedAndSendsEnter() async {
        let stdin = StdinSink()
        let launcher: GitHubAuthFlow.Launcher = {
            let stream = AsyncStream<String> { continuation in
                continuation.yield("! First copy your one-time code: ABCD-1234")
                continuation.yield("Press Enter to open https://github.com/login/device in your browser...")
                continuation.yield("Authentication complete.")
                continuation.finish()
            }
            return GitHubAuthFlow.LaunchResult(
                lines: stream,
                sendInput: { await stdin.write($0) },
                waitForExit: { 0 }
            )
        }

        let flow = GitHubAuthFlow(launcher: launcher)
        var events: [GitHubAuthFlow.Event] = []
        for await event in await flow.run() {
            events.append(event)
        }

        XCTAssertEqual(events.count, 2)
        if case .devicePrompt(let url, let code) = events[0] {
            XCTAssertEqual(url.absoluteString, "https://github.com/login/device")
            XCTAssertEqual(code, "ABCD-1234")
        } else {
            XCTFail("expected devicePrompt first, got \(events[0])")
        }
        XCTAssertEqual(events[1], .authenticated)
        let captured = await stdin.captured
        XCTAssertEqual(captured, "\n", "flow must send Enter after parsing the prompt")
    }

    func testFlowReportsFailureWhenGHExitsNonZero() async {
        let launcher: GitHubAuthFlow.Launcher = {
            let stream = AsyncStream<String> { continuation in
                continuation.yield("error: authentication declined")
                continuation.finish()
            }
            return GitHubAuthFlow.LaunchResult(
                lines: stream,
                sendInput: { _ in },
                waitForExit: { 1 }
            )
        }
        let flow = GitHubAuthFlow(launcher: launcher)
        var events: [GitHubAuthFlow.Event] = []
        for await event in await flow.run() {
            events.append(event)
        }
        XCTAssertEqual(events.count, 1)
        guard case .failed(let reason) = events[0] else { return XCTFail("expected .failed, got \(events[0])") }
        XCTAssertTrue(reason.contains("1"), "reason should mention exit code: \(reason)")
    }

    func testFlowReportsFailureWhenLauncherThrows() async {
        struct LauncherError: Error {}
        let flow = GitHubAuthFlow(launcher: {
            throw LauncherError()
        })
        var events: [GitHubAuthFlow.Event] = []
        for await event in await flow.run() {
            events.append(event)
        }
        XCTAssertEqual(events.count, 1)
        guard case .failed(let reason) = events[0] else { return XCTFail("expected .failed, got \(events[0])") }
        XCTAssertTrue(reason.lowercased().contains("gh"), reason)
    }

    func testFlowSkipsPromptWhenGHReturnsImmediately() async {
        // Happens when the user is already authenticated — gh exits 0 without printing
        // the device prompt. The flow should yield just `.authenticated`.
        let launcher: GitHubAuthFlow.Launcher = {
            let stream = AsyncStream<String> { continuation in
                continuation.yield("✓ Logged in to github.com as davidwkeith")
                continuation.finish()
            }
            return GitHubAuthFlow.LaunchResult(
                lines: stream,
                sendInput: { _ in XCTFail("should not write to stdin when no prompt parsed") },
                waitForExit: { 0 }
            )
        }
        let flow = GitHubAuthFlow(launcher: launcher)
        var events: [GitHubAuthFlow.Event] = []
        for await event in await flow.run() {
            events.append(event)
        }
        XCTAssertEqual(events, [.authenticated])
    }
}

/// Test helper: accumulates writes from `sendInput` so we can assert on them.
private actor StdinSink {
    private(set) var captured: String = ""
    func write(_ text: String) { captured.append(text) }
}
