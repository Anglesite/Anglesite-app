# HTTP/Streamable transport for the MCP edit pipeline (#63 + #64) — Design

**Status:** approved 2026-06-09 · **Part of** #59 (containerized dev server) · **design doc** [§3.2, §4](2026-05-30-cloudflare-sandbox-dev-server-design.md)

Paired, cross-repo work. The plugin (`Anglesite/anglesite`) owns the MCP message schema, so the
server-side transport lands there (#63) and ships first; the app (`Anglesite/Anglesite-app`)
consumes it (#64).

## Problem

`MCPClient` speaks JSON-RPC 2.0 over a supervised subprocess's **stdio**, parsing protocol frames
back out of `LogCenter` lines. Once the site's files and the plugin's MCP server live **inside a
container** (#66 Cloudflare / #69 Apple Containerization), the app can't spawn the server or read
its stdout — it must reach the server over **HTTP** through the container's exposed URL.

Per `CLAUDE.md`, the plugin is the source of truth for the MCP transport/schema, so the HTTP
transport is added to `anglesite/server/index.mjs` (paired PR) and the app grows a matching client
transport behind its existing actor API.

**There is no container runtime yet.** This work is verified as a vertical slice over **localhost**:
run the plugin server in HTTP mode on a port, point the Swift client at it. Production wiring to a
container endpoint arrives with #66/#69.

## Decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Transport flavor | **Streamable HTTP** — the current MCP standard (SDK `StreamableHTTPServerTransport`). Single `/mcp` endpoint; responses as `application/json` *or* `text/event-stream`; `Mcp-Session-Id` header. Not legacy two-endpoint SSE. |
| 2 | Server transport selection | **Env var, chosen at startup.** `ANGLESITE_MCP_TRANSPORT` (`"stdio"` default) → one process serves one transport. Stdio stays the default so claude's `--plugin-dir` connection and today's host-subprocess `MCPClient` are untouched. |
| 3 | Client seam | **Extract an internal `MCPTransport` protocol** with `StdioTransport` (behavior-preserved) + `HTTPTransport`. `MCPClient`'s public actor API and all call sites are unchanged. |
| 4 | Reconnect scope | Stdio respawn → re-handshake preserved exactly. HTTP handles **session loss** (re-`initialize` lazily). Full **container-restart** robustness is owned by the runtime (#66/#69) and lands with them — not faked here. |
| 5 | Schema | **Unchanged.** Only the transport is new; tool names, inputs, and reply shapes are identical across stdio and HTTP. |

## Plugin PR #63 — `anglesite/server/index.mjs`

Today the file registers tools at module top level and connects a `StdioServerTransport` at the
bottom (importing it has the side effect of connecting stdio). Refactor into exported factories so
the transport is selectable and testable:

- **`buildServer(projectRoot)`** → constructs the `McpServer`, registers every existing tool
  (`add_annotation`, `list_annotations`, `resolve_annotation`, `apply_edit`, `undo_edit`), returns
  it. *(Pure hoist — registration logic and schemas are byte-for-byte the same.)*
- **`startStdioServer({ projectRoot })`** → `buildServer` + `StdioServerTransport`. The default.
- **`startHttpServer({ projectRoot, host, port })`** → `buildServer` +
  `StreamableHTTPServerTransport` (session-managed: `sessionIdGenerator` returns a UUID, transports
  tracked by session id) wired into a Node `http` server that routes `POST`/`GET`/`DELETE /mcp` to
  `transport.handleRequest`. Returns `{ url, close }` where `url` is the **full endpoint**
  (`http://<host>:<port>/mcp`). Logs `Anglesite MCP listening on <url>` to stdout (readiness signal
  for the future runtime's probe).
- **Entry** (file bottom): read `ANGLESITE_MCP_TRANSPORT` (`"stdio"`), `ANGLESITE_MCP_HOST`
  (`127.0.0.1`), `ANGLESITE_MCP_PORT` (`4399`) and start the chosen transport. Running
  `node server/index.mjs` with no env still does stdio.

`StreamableHTTPServerTransport` is already available from `@modelcontextprotocol/sdk` (v1.28,
`server/streamableHttp.js`) — no new dependency. Session management follows the SDK's documented
pattern: a `POST /mcp` carrying `initialize` with no session header mints a new transport+session;
subsequent requests carry `Mcp-Session-Id`; `DELETE /mcp` tears the session down.

**Test (vitest):** `startHttpServer` on an ephemeral port; drive `initialize` → `tools/list` →
`list_annotations` over HTTP (raw `fetch` or the SDK client transport); assert the tool list and a
round-tripped annotation payload; `close`. No process spawn needed — exercised in-process.

## App PR #64 — `AnglesiteCore`

### `MCPTransport` (internal seam)

A duplex message channel. The shape mirrors stdio's model — a write side and a single inbound
stream of messages — so `MCPClient`'s existing id-correlation logic (`pending` map keyed by
request id) is reused verbatim:

```swift
protocol MCPTransport: Sendable {
    /// Send one framed JSON-RPC message (request or notification).
    func send(_ message: JSONValue) async throws
    /// Inbound JSON-RPC messages: responses correlated by id, plus any server notifications.
    func inbound() -> AsyncStream<JSONValue>
    func close() async
}
```

### `StdioTransport: MCPTransport`

Today's `MCPClient` internals lifted out unchanged: `supervisor.launch(..., attachStdin: true)`,
the `onRespawn` re-initialize hook, `writeStdin` newline framing, and the `LogCenter` stdout-line →
`JSONValue` parse loop feeding `inbound()`. Behavior-preserving — `MCPClientTests` stays green.

### `HTTPTransport: MCPTransport`

`URLSession`-based Streamable HTTP:

- **`send`** POSTs the message to the endpoint URL (the full `…/mcp` passed to `connect`) with headers
  `Content-Type: application/json`, `Accept: application/json, text/event-stream`,
  `MCP-Protocol-Version: 2024-11-05`, and `Mcp-Session-Id` once known.
- **Response handling:** capture `Mcp-Session-Id` from the `initialize` response; then
  - `application/json` → decode one JSON-RPC message, yield to `inbound()`.
  - `text/event-stream` → parse SSE frames, decode each `data:` payload as a JSON-RPC message,
    yield each to `inbound()` until the server closes the short-lived stream.
  - `202 Accepted` (notifications) → no message.
- **Session loss** (connection refused, or `404` "session not found") → drop the session id; the
  next `MCPClient` call re-runs `initialize` (the in-flight call surfaces `.reconnecting`).

A standalone, network-free SSE frame parser (`data:` accumulation, blank-line dispatch, multi-line
data) is a pure function so it's unit-tested directly.

### `MCPClient` changes

Keeps `nextRequestID`, `pending`, `sendRequest`, `sendNotification`, the `initialize`/`notifications/initialized`
handshake, and `consumeResponses` — now reading `transport.inbound()` and writing via
`transport.send()` instead of touching the supervisor/`LogCenter` directly.

- `start(executable:arguments:…)` builds a `StdioTransport` (same external surface and defaults).
- New `connect(httpEndpoint: URL, …)` builds an `HTTPTransport`, then runs the shared
  reader-start + handshake path.

`listTools` / `callTool` / `stop` and the call sites (`PreviewSession`/`LocalSiteRuntime`,
`MCPApplyEditRouter`) are unchanged.

### Tests (Swift)

- `MCPClientTests` (stdio) — unchanged, stays green (proves the extraction preserved behavior).
- `SSEFrameParserTests` — pure parser unit tests, no network.
- `HTTPTransportTests` (end-to-end) — spawn `node server/index.mjs` with
  `ANGLESITE_MCP_TRANSPORT=http` against a tmp fixture project, `connect(httpEndpoint:)`, run
  `listTools` + a `callTool`, assert. Guarded to `XCTSkip`-equivalent when Node ≥22 / the bundled
  plugin isn't present (mirrors `AppliesEditEndToEndTests`).

## Data flow (HTTP, one `callTool`)

```
MCPClient.callTool(name:args:)
  → sendRequest(method:"tools/call", id:N)
     → transport.send({jsonrpc,id:N,method,params})        HTTPTransport: POST /mcp (+session header)
                                                            server: StreamableHTTPServerTransport → McpServer tool
       ← response over application/json or text/event-stream
       → HTTPTransport decodes → inbound() yields {id:N,result}
  → consumeResponses sees id:N → resolves pending[N]
  → callTool maps result → ToolCallResult
```

Identical to the stdio path from `sendRequest` inward; only the transport differs.

## Sequencing & integration

1. **Plugin #63 first** (it blocks #64): land + merge the HTTP transport in `anglesite`.
2. **App #64**: the app's bundled-plugin copy (`scripts/copy-plugin.sh` from the sibling checkout
   or `$ANGLESITE_PLUGIN_SRC`) picks up the HTTP-capable `server/index.mjs`; the
   `.bundled-from-commit` stamp records the source commit. The Swift `HTTPTransportTests` spawn that
   bundled server in HTTP mode for the end-to-end check.

Two paired PRs, plugin first. No production call site switches to `connect(httpEndpoint:)` in this
slice — `LocalSiteRuntime` keeps using stdio until #70 retires it; #66/#69 are the first real HTTP
consumers.

## Non-goals

- Container lifecycle, tunnels, bearer tokens (#66/#67/#69).
- Deleting stdio (#70, after the host-subprocess path is gone).
- Server→client streaming notifications (`GET /mcp` SSE) — the client opens no long-lived stream;
  it consumes only per-request responses. The seam leaves room for it (`inbound()` is already a
  stream) without building it now.
