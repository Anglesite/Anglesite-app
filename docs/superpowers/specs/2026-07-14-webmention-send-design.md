# Webmention Send on Publish — Design

**Date:** 2026-07-14
**Status:** Decided
**Part of:** #354 (V-2.2), #336 (V-2 epic), #334 (Personal Publishing OS pivot)
**Relates to:** [`docs/specs/2026-06-29-c2-workers-integration-seam.md`](../../specs/2026-06-29-c2-workers-integration-seam.md)

---

## Decision

Issue #354 and its parent epic #336 gate V-2 ("send webmentions") on a conformant `@dwk/workers`
release (`@dwk/webmention` + `@dwk/indieauth` both release-ready per `WorkersConformanceReader`).
As of this writing `@dwk/workers` is unpublished (`npm view @dwk/workers` 404s), so the literal
scope — sending routed through the per-site Worker's composed `@dwk/webmention` package — remains
blocked.

**Webmention *sending* does not actually need the per-site Worker.** The c2 integration seam's
`/webmention` route (`c2-workers-integration-seam.md:23`) is the *receiving* endpoint a site
exposes for others to notify it — that's V-3 territory (inbound webmentions), not this issue.
Sending is a client-side operation defined entirely by the public webmention.org spec: discover
the target's declared endpoint, then `POST` `source`+`target` form-encoded. Nothing about that
requires the sending site's own infrastructure.

This mirrors the precedent set by V-2.1 (#353, PR #430), which shipped per-site Worker
provisioning as pure Cloudflare/wrangler plumbing ahead of the same gate. This design ships a
pure-Swift `WebmentionSender` in `AnglesiteCore`, wired into the existing deploy pipeline,
independent of `@dwk/workers` publication. When `@dwk/workers` does ship, receiving (V-3) is
unaffected by this decision, and nothing here needs to be revisited — sending stays client-side
permanently per the webmention spec.

## Components

Four new types in `AnglesiteCore`, following existing conventions (`DeployCommand`'s
closure-injected seams, `DeployedRoutesSnapshot`'s `Config/`-persistence shape):

### `WebmentionEndpointDiscovery`

Given a target `URL` and an injectable HTTP-fetch closure, issues one GET and determines the
target's declared webmention endpoint:

1. Check the response's `Link` header for `rel="webmention"` (or `rel="http://webmention.org/"`,
   the legacy form some implementations still emit).
2. If absent, parse the HTML body for `<link rel="webmention" href="...">` or
   `<a rel="webmention" href="...">` (first match wins, matching the spec's "first" rule).
3. Resolve a relative `href`/`Link` target against the *final* response URL (post-redirect), not
   the originally-requested URL — required for webmention.rocks' redirect test pages.

Returns `URL?` — `nil` means no endpoint declared (not an error; most links on the web don't have
one).

```swift
public typealias WebmentionHTTPFetch = @Sendable (URL) async throws -> (data: Data, response: HTTPURLResponse)

public enum WebmentionEndpointDiscovery {
    public static func discover(target: URL, fetch: WebmentionHTTPFetch) async throws -> URL?
}
```

### `WebmentionSender`

Given a `(source, target)` pair, discovers the endpoint via `WebmentionEndpointDiscovery`, then
`POST`s `source=<source>&target=<target>` as `application/x-www-form-urlencoded` to it.

```swift
public enum WebmentionSendOutcome: Equatable, Sendable {
    case sent(endpoint: URL, statusCode: Int)
    case noEndpointDiscovered
    case requestFailed(reason: String)
}

public enum WebmentionSender {
    public static func send(
        source: URL,
        target: URL,
        fetch: WebmentionHTTPFetch,
        post: @Sendable (URL, Data) async throws -> (data: Data, response: HTTPURLResponse)
    ) async -> WebmentionSendOutcome
}
```

A 2xx response (200/201/202 — 202 covers receivers that queue async processing) is `.sent`.
Anything else is `.requestFailed`. No retry logic here — retries happen naturally at the
`WebmentionSendCommand` level (see below): a failed pair is never recorded as sent, so it's
retried on the next deploy.

### `WebmentionSentLog`

Per-site record of which `(source, target)` pairs have already been sent successfully, so
redeploying a site doesn't re-ping every target on every deploy. Lives in the site's own
`Config/` — per-site by construction, same place as `last-deployed-routes.json` and
`settings.plist` (never committed to the site's git repo, per the package model).

`Config/webmention-sent.json`:

```json
{
  "sent": [
    {
      "source": "https://example.com/posts/foo/",
      "target": "https://target.example/bar",
      "sentAt": "2026-07-14T18:03:00Z"
    }
  ]
}
```

```swift
public struct WebmentionSentLog: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let source: URL
        public let target: URL
        public let sentAt: Date
    }
    public let sent: [Entry]

    public static let filename = "webmention-sent.json"
    public static func load(from configDirectory: URL) -> WebmentionSentLog?
    public func save(to configDirectory: URL) throws

    /// Pairs present in `plan` not already recorded in `self`.
    public func pending(in plan: SocialPublishPlan.Plan) -> [(source: URL, target: URL)]

    /// Returns a new log with `pairs` appended, stamped via `now()`.
    public func recording(
        _ pairs: [(source: URL, target: URL)],
        now: @escaping () -> Date = Date.init
    ) -> WebmentionSentLog
}
```

### `WebmentionSendCommand`

Actor orchestrator, mirrors `DeployCommand`'s shape. One entry point:

```swift
public actor WebmentionSendCommand {
    public init(
        fetch: @escaping WebmentionHTTPFetch = Self.defaultFetch,
        post: @escaping @Sendable (URL, Data) async throws -> (data: Data, response: HTTPURLResponse) = Self.defaultPost,
        logCenter: LogCenter = .shared
    )

    /// Builds the site's SocialPublishPlan (siteBase = the just-deployed URL), diffs it against
    /// the site's WebmentionSentLog, sends each pending pair, persists successes, and streams
    /// progress/results into LogCenter under source "webmention:<siteID>". Best-effort — never
    /// throws; failures are logged, not surfaced as a thrown error, since this runs detached
    /// from the deploy result the user actually watches.
    public func send(
        siteID: String,
        siteDirectory: URL,
        configDirectory: URL,
        siteBase: URL
    ) async
}
```

Real `fetch`/`post` defaults are thin `URLSession.shared` wrappers. Tests inject fakes — no real
network calls in the unit suite.

## Wiring into the deploy pipeline

`DeployModel` (`Sources/AnglesiteApp/DeployModel.swift`) gains a new dependency, injected the same
way `command: DeployCommand` already is:

```swift
private let webmentionCommand: WebmentionSendCommand

init(
    command: DeployCommand = DeployCommand(),
    webmentionCommand: WebmentionSendCommand = WebmentionSendCommand(),
    ...
)
```

In `runDeploy`, right after the phase transition to `.succeeded`:

```swift
case .succeeded(let url, let duration):
    transition(siteID: siteID, to: .succeeded(url: url, duration: duration))
    Task.detached { [webmentionCommand] in
        await webmentionCommand.send(
            siteID: siteID,
            siteDirectory: siteDirectory,
            configDirectory: configDirectory,
            siteBase: url
        )
    }
```

Fire-and-forget, on the deployed URL — matches the "background, after `.succeeded`" decision. The
deploy UI (phase, drawer, Dock progress, notifications) is unaffected; webmention activity is
visible only through `LogCenter`, same as build/wrangler output, under a distinct
`"webmention:<siteID>"` source so it doesn't get folded into the deploy drawer's line filter. No
new Settings toggle — this runs automatically on every successful deploy, same posture as the
pre-deploy scan being unconditional. A failed or partial send run doesn't affect deploy success;
it's picked up again on the next deploy via `WebmentionSentLog`'s pending-diff.

## Testing strategy

**Unit tests (always run, no network):**
- `WebmentionEndpointDiscoveryTests` — fixture HTML/headers modeled on webmention.rocks' documented
  cases: `Link` header, `<link>` element, `<a>` element, relative-URL resolution, redirect-then-
  discover, no endpoint present, multiple candidates (first wins).
- `WebmentionSenderTests` — fake HTTP executor; assert POST body/headers/content-type and the
  2xx/4xx/5xx → `SendOutcome` mapping.
- `WebmentionSentLogTests` — save/load round-trip, `pending(in:)` diff correctness.
- `WebmentionSendCommandTests` — full orchestration against a fixture site directory (same fixture
  style as `SocialPublishPlanTests`), fake fetch/post, asserting the log is updated only for
  successes and `LogCenter` receives the expected lines.

**Gated live e2e test:** one test hitting several real `webmention.rocks/test/N` pages, skipped
unless `ANGLESITE_WEBMENTION_E2E=1` is set — mirrors `ANGLESITE_CONTAINER_E2E`'s pattern so CI
doesn't depend on network/third-party availability by default. Exercises the real discovery +
POST path against real-world markup variations.

**Manual acceptance step:** webmention.rocks' full pass/fail dashboard requires visiting their
site and using a session-specific source-URL token they crawl back to verify — that's inherently
interactive and not something to automate. Done once during implementation; the result is noted in
the PR description, not re-checked by CI.

## Non-goals

- Receiving webmentions (inbound `/webmention` route) — V-3, gated separately, unrelated to this
  slice.
- POSSE syndication — V-2.4, separate sub-issue.
- Any UI surface beyond `LogCenter` — no Settings toggle, no per-site results view. Can follow
  later if the LogCenter-only visibility proves insufficient in practice.
