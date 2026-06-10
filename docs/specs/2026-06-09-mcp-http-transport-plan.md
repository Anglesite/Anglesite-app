# HTTP/Streamable MCP transport — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Streamable HTTP transport to the plugin's MCP server (alongside stdio) and a matching `HTTPTransport` to the Swift `MCPClient`, behind an internal `MCPTransport` seam, verified end-to-end over localhost.

**Architecture:** Plugin `server/index.mjs` is refactored into `buildServer`/`startStdioServer`/`startHttpServer` factories; the transport is chosen at startup by `ANGLESITE_MCP_TRANSPORT` (stdio default). The Swift `MCPClient` keeps all JSON-RPC id-correlation/handshake logic and delegates raw message send/receive to one of two `MCPTransport` conformers — `StdioTransport` (today's behavior, lifted verbatim) or `HTTPTransport` (Streamable HTTP over `URLSession`). No schema change; no production call site switches to HTTP in this slice.

**Tech Stack:** Node 22 + `@modelcontextprotocol/sdk` 1.28 (`StreamableHTTPServerTransport`) + vitest (plugin); Swift actors + `URLSession` + Swift Testing (app).

**Spec:** [`2026-06-09-mcp-http-transport-design.md`](2026-06-09-mcp-http-transport-design.md)

**Two repos:** Phase A lands in the sibling plugin repo `../anglesite` (#63, merges first). Phase B lands in this app repo `Anglesite-app` (#64).

---

## File structure

**Phase A — `../anglesite` (plugin):**
- Modify: `server/index.mjs` — split into `buildServer` / `startStdioServer` / `startHttpServer` + env-driven entry.
- Create: `server/http-server.mjs` — the Node `http` + `StreamableHTTPServerTransport` glue (keeps `index.mjs` small).
- Create: `test/mcp-http-transport.test.js` — vitest HTTP round-trip.

**Phase B — `Anglesite-app` (app):**
- Create: `Sources/AnglesiteCore/MCPTransport.swift` — the seam protocol.
- Create: `Sources/AnglesiteCore/StdioTransport.swift` — extracted stdio transport.
- Create: `Sources/AnglesiteCore/HTTPTransport.swift` — Streamable HTTP transport + SSE frame parser.
- Modify: `Sources/AnglesiteCore/MCPClient.swift` — delegate to a transport; add `connect(httpEndpoint:)`.
- Create: `Tests/AnglesiteCoreTests/SSEFrameParserTests.swift` — pure parser tests.
- Create: `Tests/AnglesiteCoreTests/HTTPTransportTests.swift` — URLProtocol-stub unit tests.
- Create: `Tests/AnglesiteCoreTests/MCPClientHTTPEndToEndTests.swift` — spawn the plugin server in HTTP mode, drive the real client.
- Existing, kept green: `Tests/AnglesiteCoreTests/MCPClientTests.swift` (stdio).

**Toolchain note (every Swift `swift test`/`xcodebuild` step):** prefix with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` — the default `xcode-select` points at CommandLineTools, which can't run `swift test`.

---

# Phase A — Plugin HTTP transport (`../anglesite`, #63)

### Task A1: Extract `buildServer` from `index.mjs` (pure refactor, stdio behavior preserved)

**Files:**
- Modify: `../anglesite/server/index.mjs`

- [ ] **Step 1: Refactor — wrap tool registration in `buildServer(projectRoot)` and export it**

Replace the top-level `const server = new McpServer(...)` + all `server.tool(...)` calls + the trailing
`const transport = new StdioServerTransport(); await server.connect(transport);` with a factory plus a
stdio entry. The tool bodies are unchanged — only their enclosing scope moves.

```javascript
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import {
  addAnnotation,
  listAnnotations,
  resolveAnnotation,
} from "./annotations.mjs";
import { applyEditInputShape } from "./apply-edit-schema.mjs";
import { applyEdit } from "./apply-edit-dispatcher.mjs";
import { recordEdit } from "./edit-history.mjs";
import { undoEdit } from "./undo-edit.mjs";

/**
 * Build the Anglesite MCP server with every tool registered against `projectRoot`.
 * Transport-agnostic — the caller connects it to stdio or HTTP.
 */
export function buildServer(projectRoot) {
  const server = new McpServer({
    name: "anglesite-annotations",
    version: "0.16.4",
  });

  server.tool(
    "add_annotation",
    "Pin a feedback note to a page element",
    {
      path: z.string().describe("Page path, e.g. /about"),
      selector: z.string().describe("CSS selector of the target element"),
      text: z.string().describe("The feedback note text"),
      sourceFile: z
        .string()
        .optional()
        .describe("Source file path, e.g. src/pages/about.astro"),
    },
    ({ path, selector, text, sourceFile }) => {
      const annotation = addAnnotation(projectRoot, { path, selector, text, sourceFile });
      return { content: [{ type: "text", text: JSON.stringify(annotation) }] };
    },
  );

  server.tool(
    "list_annotations",
    "List unresolved feedback annotations",
    { path: z.string().optional().describe("Filter by page path") },
    ({ path }) => {
      const annotations = listAnnotations(projectRoot, path);
      return { content: [{ type: "text", text: JSON.stringify(annotations) }] };
    },
  );

  server.tool(
    "resolve_annotation",
    "Mark a feedback annotation as resolved",
    { id: z.string().describe("Annotation ID to resolve") },
    ({ id }) => {
      try {
        const annotation = resolveAnnotation(projectRoot, id);
        return { content: [{ type: "text", text: JSON.stringify(annotation) }] };
      } catch (error) {
        return { content: [{ type: "text", text: error.message }], isError: true };
      }
    },
  );

  server.tool(
    "apply_edit",
    "Apply an edit to the underlying source for a previewed page element. The selector is the structured ElementInfo payload built by the WKWebView overlay; the server resolves it via selector.mjs and patches the matching source file. Successful edits are also committed onto the hidden anglesite/edits branch for per-edit undo.",
    applyEditInputShape,
    async (input) =>
      applyEdit(projectRoot, input, {
        onApplied: ({ file, range }) =>
          recordEdit(projectRoot, { file, range, message: `anglesite: edit ${file}` }),
      }),
  );

  server.tool(
    "undo_edit",
    "Undo the most-recent commit on the hidden anglesite/edits branch by writing the parent commit's blobs back to disk. HEAD-only in v1: an optional `commit` argument must equal current HEAD (or be omitted). `force: true` skips the working-tree-modification check and overwrites any external changes to the touched files.",
    {
      commit: z.string().optional().describe("SHA to undo. Must equal current HEAD of refs/heads/anglesite/edits if provided."),
      force: z.boolean().optional().describe("Skip the working-tree-modification check and overwrite any external changes. Default false."),
    },
    async ({ commit, force }) => {
      const result = await undoEdit(projectRoot, { commit, force });
      return {
        content: [{ type: "text", text: JSON.stringify(result) }],
        isError: result.status === "refused",
      };
    },
  );

  return server;
}

/** Connect a freshly built server to stdio. The default transport. */
export async function startStdioServer({ projectRoot }) {
  const server = buildServer(projectRoot);
  await server.connect(new StdioServerTransport());
  return server;
}

const projectRoot = process.env.ANGLESITE_PROJECT_ROOT || process.cwd();
await startStdioServer({ projectRoot });
```

- [ ] **Step 2: Verify the existing plugin suite still passes**

Run: `cd ../anglesite && npm test`
Expected: PASS (this is a pure hoist; no test should change).

- [ ] **Step 3: Smoke-test stdio by hand**

Run: `cd ../anglesite && printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' | ANGLESITE_PROJECT_ROOT=$(mktemp -d) node server/index.mjs`
Expected: a single JSON line containing `"result"` with `serverInfo.name":"anglesite-annotations"`, then the process waits on stdin (Ctrl-C to exit).

- [ ] **Step 4: Commit**

```bash
cd ../anglesite
git add server/index.mjs
git commit -m "refactor(server): extract buildServer/startStdioServer (no behavior change)"
```

---

### Task A2: Add `startHttpServer` (Streamable HTTP)

**Files:**
- Create: `../anglesite/server/http-server.mjs`
- Create: `../anglesite/test/mcp-http-transport.test.js`

- [ ] **Step 1: Write the failing test**

```javascript
// ../anglesite/test/mcp-http-transport.test.js
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { startHttpServer } from "../server/http-server.mjs";

describe("MCP Streamable HTTP transport", () => {
  let root;
  let handle;

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), "mcp-http-"));
  });

  afterEach(async () => {
    if (handle) await handle.close();
    handle = undefined;
    rmSync(root, { recursive: true, force: true });
  });

  it("serves initialize, tools/list and a tool call over HTTP", async () => {
    handle = await startHttpServer({ projectRoot: root, host: "127.0.0.1", port: 0 });
    expect(handle.url).toMatch(/^http:\/\/127\.0\.0\.1:\d+\/mcp$/);

    const client = new Client({ name: "test", version: "0.0.0" });
    await client.connect(new StreamableHTTPClientTransport(new URL(handle.url)));

    const { tools } = await client.listTools();
    const names = tools.map((t) => t.name).sort();
    expect(names).toContain("list_annotations");
    expect(names).toContain("apply_edit");

    // list_annotations on an empty project returns an empty JSON array.
    const res = await client.callTool({ name: "list_annotations", arguments: {} });
    expect(res.isError).toBeFalsy();
    expect(JSON.parse(res.content[0].text)).toEqual([]);

    await client.close();
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd ../anglesite && npx vitest run test/mcp-http-transport.test.js`
Expected: FAIL — `Cannot find module '../server/http-server.mjs'`.

- [ ] **Step 3: Implement `startHttpServer`**

`port: 0` asks the OS for a free port; we read the real port back off the listening server.

```javascript
// ../anglesite/server/http-server.mjs
import { createServer } from "node:http";
import { randomUUID } from "node:crypto";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { isInitializeRequest } from "@modelcontextprotocol/sdk/types.js";
import { buildServer } from "./index-tools.mjs";

/** Read and JSON-parse a request body. Returns `undefined` for an empty body. */
function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let raw = "";
    req.on("data", (chunk) => { raw += chunk; });
    req.on("end", () => {
      if (!raw) return resolve(undefined);
      try { resolve(JSON.parse(raw)); } catch (e) { reject(e); }
    });
    req.on("error", reject);
  });
}

function sendJson(res, status, payload) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(payload));
}

/**
 * Start the Anglesite MCP server over Streamable HTTP on a single `/mcp` endpoint.
 * Session-managed: an `initialize` POST mints a session + per-session transport;
 * subsequent requests carry `Mcp-Session-Id`.
 *
 * Returns `{ url, close }` where `url` is the full endpoint (`http://host:port/mcp`).
 */
export async function startHttpServer({ projectRoot, host = "127.0.0.1", port = 4399 }) {
  /** @type {Map<string, StreamableHTTPServerTransport>} */
  const transports = new Map();

  const httpServer = createServer(async (req, res) => {
    try {
      const url = new URL(req.url, `http://${req.headers.host}`);
      if (url.pathname !== "/mcp") { res.writeHead(404).end(); return; }

      const sid = req.headers["mcp-session-id"];

      if (req.method === "POST") {
        const body = await readJsonBody(req);
        let transport = typeof sid === "string" ? transports.get(sid) : undefined;

        if (!transport) {
          if (!isInitializeRequest(body)) {
            sendJson(res, 400, {
              jsonrpc: "2.0",
              error: { code: -32000, message: "Bad Request: no valid session ID provided" },
              id: null,
            });
            return;
          }
          transport = new StreamableHTTPServerTransport({ sessionIdGenerator: () => randomUUID() });
          transport.onclose = () => {
            if (transport.sessionId) transports.delete(transport.sessionId);
          };
          const server = buildServer(projectRoot);
          await server.connect(transport);
        }

        await transport.handleRequest(req, res, body);
        if (transport.sessionId) transports.set(transport.sessionId, transport);
        return;
      }

      if (req.method === "GET" || req.method === "DELETE") {
        const transport = typeof sid === "string" ? transports.get(sid) : undefined;
        if (!transport) { res.writeHead(400).end("Invalid or missing session ID"); return; }
        await transport.handleRequest(req, res);
        return;
      }

      res.writeHead(405).end();
    } catch (err) {
      if (!res.headersSent) sendJson(res, 500, { jsonrpc: "2.0", error: { code: -32603, message: String(err) }, id: null });
    }
  });

  await new Promise((resolve) => httpServer.listen(port, host, resolve));
  const actualPort = httpServer.address().port;
  const endpoint = `http://${host}:${actualPort}/mcp`;
  console.log(`Anglesite MCP listening on ${endpoint}`);

  return {
    url: endpoint,
    close: () =>
      new Promise((resolve) => {
        for (const t of transports.values()) t.close?.();
        transports.clear();
        httpServer.close(() => resolve());
      }),
  };
}
```

`http-server.mjs` imports `buildServer` from `./index-tools.mjs`, but `buildServer` currently lives in
`index.mjs` (which has a top-level `await startStdioServer` side effect on import). To import the
factory without that side effect, move `buildServer` + `startStdioServer` into a new
`server/index-tools.mjs` and have `index.mjs` re-export + run the entry. Do that in Step 4.

- [ ] **Step 4: Split the importable factories out of the entry file**

Create `../anglesite/server/index-tools.mjs` containing the `buildServer` and `startStdioServer`
definitions from Task A1 (move them verbatim, keep the same imports). Then reduce
`../anglesite/server/index.mjs` to the entry only:

```javascript
// ../anglesite/server/index.mjs
import { startStdioServer } from "./index-tools.mjs";
import { startHttpServer } from "./http-server.mjs";

const projectRoot = process.env.ANGLESITE_PROJECT_ROOT || process.cwd();
const transport = (process.env.ANGLESITE_MCP_TRANSPORT || "stdio").toLowerCase();

if (transport === "http") {
  const host = process.env.ANGLESITE_MCP_HOST || "127.0.0.1";
  const port = Number(process.env.ANGLESITE_MCP_PORT || "4399");
  await startHttpServer({ projectRoot, host, port });
} else {
  await startStdioServer({ projectRoot });
}
```

Update the test import in `test/mcp-http-transport.test.js` if needed (it already imports from
`../server/http-server.mjs`, which imports `./index-tools.mjs` — no change). Any other module that
imported `buildServer`/`startStdioServer` from `index.mjs` must now import from `index-tools.mjs`
(grep: `cd ../anglesite && grep -rn "from \"./index.mjs\"\|from \"../server/index.mjs\"" server test`).

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd ../anglesite && npx vitest run test/mcp-http-transport.test.js`
Expected: PASS.

- [ ] **Step 6: Run the full plugin suite (no regressions)**

Run: `cd ../anglesite && npm test`
Expected: PASS.

- [ ] **Step 7: Smoke-test HTTP mode by hand**

Run:
```bash
cd ../anglesite
ANGLESITE_MCP_TRANSPORT=http ANGLESITE_MCP_PORT=4399 ANGLESITE_PROJECT_ROOT=$(mktemp -d) node server/index.mjs &
sleep 1
curl -sS -i -X POST http://127.0.0.1:4399/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2024-11-05' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
kill %1
```
Expected: HTTP 200 with an `Mcp-Session-Id` response header and a body (either `application/json` or
`text/event-stream` carrying the `initialize` result). Confirms the `Mcp-Session-Id` header and SSE
body shape the Swift client must handle.

- [ ] **Step 8: Commit**

```bash
cd ../anglesite
git add server/index.mjs server/index-tools.mjs server/http-server.mjs test/mcp-http-transport.test.js
git commit -m "feat(server): Streamable HTTP transport behind ANGLESITE_MCP_TRANSPORT=http (#63)"
```

---

### Task A3: Open the plugin PR

- [ ] **Step 1: Push + PR**

```bash
cd ../anglesite
git checkout -b feat/mcp-http-transport-63
git push -u origin feat/mcp-http-transport-63
gh pr create --base main --title "feat(server): HTTP/Streamable MCP transport (#63)" \
  --body "Adds a Streamable HTTP transport alongside stdio, selected by ANGLESITE_MCP_TRANSPORT (stdio default — claude --plugin-dir and the host-subprocess MCPClient are untouched). Schema unchanged. Paired with Anglesite-app #64. Closes #63."
```

> Note: A3 assumes the work was done on a branch. If Tasks A1–A2 were committed on `main`, instead
> create the branch *before* committing, or `git branch feat/mcp-http-transport-63 && git reset --hard origin/main` on main after noting the SHA. Coordinate with the maintainer; the plugin PR merges before Phase B's end-to-end test can run against the bundled copy.

---

# Phase B — App `MCPClient` HTTP transport (`Anglesite-app`, #64)

> Work on branch `feat/mcp-http-transport-64` (already created off `origin/main`; the design doc is
> already committed there).

### Task B1: Define `MCPTransport` and extract `StdioTransport` (keep `MCPClientTests` green)

**Files:**
- Create: `Sources/AnglesiteCore/MCPTransport.swift`
- Create: `Sources/AnglesiteCore/StdioTransport.swift`
- Modify: `Sources/AnglesiteCore/MCPClient.swift`
- Test (unchanged, must pass): `Tests/AnglesiteCoreTests/MCPClientTests.swift`

- [ ] **Step 1: Create the seam protocol**

```swift
// Sources/AnglesiteCore/MCPTransport.swift
import Foundation

/// A duplex channel for MCP JSON-RPC messages. `MCPClient` owns all id-correlation, timeout, and
/// handshake logic and delegates raw message send/receive to a transport. The shape mirrors stdio's
/// model — a write side plus one inbound stream of decoded messages — so HTTP and stdio share the
/// same client code path.
///
/// Conformers own mutable connection state, so each is an `actor`.
public protocol MCPTransport: Sendable {
    /// Establish the connection. After this returns, `inbound()` is live. Idempotent transports may
    /// no-op (HTTP has no persistent connection to open).
    func open() async throws
    /// Send one framed JSON-RPC message (request or notification).
    func send(_ message: JSONValue) async throws
    /// Inbound JSON-RPC messages: responses (correlated by id downstream) plus server notifications.
    /// Call once; returns the single backing stream.
    func inbound() -> AsyncStream<JSONValue>
    /// Tear down the connection and finish the inbound stream.
    func close() async
}
```

- [ ] **Step 2: Extract `StdioTransport` from the current `MCPClient` internals**

This is the verbatim stdio behavior — `supervisor.launch(attachStdin:)`, the `onRespawn` hook (now a
caller-supplied `onReconnect` closure), newline framing, and the `LogCenter` stdout-line → `JSONValue`
parse — lifted out of `MCPClient` into its own actor.

```swift
// Sources/AnglesiteCore/StdioTransport.swift
import Foundation

/// `MCPTransport` over a supervised subprocess's stdio (today's only transport). `send` writes a
/// newline-framed JSON object to the child's stdin via the supervisor; `inbound()` yields each
/// stdout line (filtered to this transport's `source`) parsed as a `JSONValue`. On a supervised
/// respawn the supervisor calls `onReconnect`, which `MCPClient` uses to re-run its handshake.
public actor StdioTransport: MCPTransport {
    private let supervisor: ProcessSupervisor
    private let logCenter: LogCenter
    private let source: String
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let currentDirectoryURL: URL?
    private let restartPolicy: ProcessSupervisor.RestartPolicy
    private let onReconnect: @Sendable () async -> Void

    private var handle: ProcessSupervisor.Handle?
    private var subscription: LogCenter.Subscription?
    private var forwardTask: Task<Void, Never>?

    private let stream: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation

    public init(
        supervisor: ProcessSupervisor,
        logCenter: LogCenter,
        source: String,
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL?,
        restartPolicy: ProcessSupervisor.RestartPolicy,
        onReconnect: @escaping @Sendable () async -> Void
    ) {
        self.supervisor = supervisor
        self.logCenter = logCenter
        self.source = source
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.restartPolicy = restartPolicy
        self.onReconnect = onReconnect
        (self.stream, self.continuation) = AsyncStream<JSONValue>.makeStream(bufferingPolicy: .unbounded)
    }

    public func open() async throws {
        let sub = await logCenter.subscribe()
        self.subscription = sub
        let h = try await supervisor.launch(
            source: source,
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL,
            restartPolicy: restartPolicy,
            attachStdin: true,
            onRespawn: { [onReconnect] in await onReconnect() },
            logCenter: logCenter
        )
        self.handle = h
        // Forward parsed stdout frames into the inbound stream. Captures only value types + the
        // subscription stream — no `self` — so the task doesn't keep the transport alive.
        forwardTask = Task { [source, continuation] in
            for await line in sub.stream {
                guard line.source == source, line.stream == .stdout else { continue }
                guard let data = line.text.data(using: .utf8),
                      let raw = try? JSONSerialization.jsonObject(with: data),
                      let value = JSONValue.from(raw)
                else { continue }
                continuation.yield(value)
            }
        }
    }

    public func send(_ message: JSONValue) async throws {
        guard let handle else { throw MCPClient.MCPError.notInitialized }
        var data = try JSONSerialization.data(withJSONObject: message.rawValue, options: [])
        data.append(0x0A)  // '\n' — one JSON object per line; framing must be byte-identical.
        do {
            try await supervisor.writeStdin(handle, data)
        } catch {
            throw MCPClient.MCPError.notInitialized
        }
    }

    public func inbound() -> AsyncStream<JSONValue> { stream }

    public func close() async {
        forwardTask?.cancel()
        forwardTask = nil
        subscription?.cancel()
        subscription = nil
        if let h = handle {
            await supervisor.terminate(h, timeout: 2)
            _ = await supervisor.waitForExit(h)
        }
        handle = nil
        continuation.finish()
    }
}
```

- [ ] **Step 3: Rewire `MCPClient` to delegate to a transport**

Replace the stdio-specific fields and methods in `MCPClient.swift`. Keep `JSONValue`, `MCPError`,
`ToolDescriptor`, `ToolCallResult`, `nextRequestID`, `pending`, `initialized`, the handshake, and
`listTools`/`callTool` exactly as they are. Apply these specific edits:

(a) Replace the stored-properties block (the `supervisor`/`logCenter`/`handle`/`subscription`/`readerTask`/`source` set) with:

```swift
    private var transport: (any MCPTransport)?
    private var readerTask: Task<Void, Never>?

    // Stdio construction inputs retained so `start(...)` can build a StdioTransport.
    private let supervisor: ProcessSupervisor
    private let logCenter: LogCenter

    private var nextRequestID: Int = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var initialized: Bool = false

    private var clientName: String = "Anglesite"
    private var clientVersion: String = "0.1.0"
    private var initializeTimeout: TimeInterval = 10
```

(b) Keep the existing `init(supervisor:logCenter:)` unchanged. Change `isRunning`:

```swift
    public var isRunning: Bool { transport != nil }
```

(c) Replace the body of `start(executable:...)` (keep its signature) so it builds a `StdioTransport`
and defers to a shared starter:

```swift
    public func start(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        source: String = "mcp",
        currentDirectoryURL: URL? = nil,
        restartPolicy: ProcessSupervisor.RestartPolicy = .onCrash(maxAttempts: 3, baseBackoff: 1.0),
        initializeTimeout: TimeInterval = 10,
        clientName: String = "Anglesite",
        clientVersion: String = "0.1.0"
    ) async throws {
        let t = StdioTransport(
            supervisor: supervisor,
            logCenter: logCenter,
            source: source,
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL,
            restartPolicy: restartPolicy,
            onReconnect: { [weak self] in await self?.handleRespawn() }
        )
        try await startWithTransport(t, initializeTimeout: initializeTimeout, clientName: clientName, clientVersion: clientVersion)
    }

    /// Shared start path for any transport: open, start the reader, run the initialize handshake.
    func startWithTransport(
        _ t: any MCPTransport,
        initializeTimeout: TimeInterval,
        clientName: String,
        clientVersion: String
    ) async throws {
        if transport != nil { throw MCPError.alreadyRunning }
        self.transport = t
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.initializeTimeout = initializeTimeout
        try await t.open()
        readerTask = Task { [weak self] in
            guard let self else { return }
            await self.consumeResponses(t.inbound())
        }
        do {
            try await runInitializeHandshake()
            self.initialized = true
        } catch {
            await teardown()
            throw error
        }
    }
```

(d) Change `writeJSONLine` to delegate to the transport (rename it `send` for clarity, update its two
call sites in `sendRequest`/`sendNotification`):

```swift
    private func send(_ value: JSONValue) async throws {
        guard let transport else { throw MCPError.notInitialized }
        try await transport.send(value)
    }
```

In `sendRequest`, replace `try await writeJSONLine(.object(obj))` with `try await send(.object(obj))`.
In `sendNotification`, replace `try await writeJSONLine(.object(obj))` with `try await send(.object(obj))`.

(e) Replace `consumeResponses(_ stream: AsyncStream<LogCenter.LogLine>, source: String)` with the
`JSONValue` version (the transport already decoded + filtered):

```swift
    private func consumeResponses(_ stream: AsyncStream<JSONValue>) async {
        for await message in stream {
            guard case .object(let obj) = message else { continue }
            guard case .int(let id)? = obj["id"] else { continue }  // responses only

            if case .object(let errObj)? = obj["error"] {
                let code: Int = { if case .int(let c)? = errObj["code"] { return c }; return -1 }()
                let msg: String = { if case .string(let m)? = errObj["message"] { return m }; return "unknown rpc error" }()
                failPending(id: id, error: MCPError.rpcError(code: code, message: msg))
                continue
            }
            if let result = obj["result"] {
                resolvePending(id: id, value: result)
            } else {
                resolvePending(id: id, value: .null)
            }
        }
    }
```

(f) Replace `teardown()` to use the transport:

```swift
    private func teardown() async {
        readerTask?.cancel()
        readerTask = nil
        if let transport { await transport.close() }
        transport = nil
        initialized = false
        for (_, cont) in pending { cont.resume(throwing: MCPError.notInitialized) }
        pending.removeAll()
    }
```

Leave `handleRespawn()`, `runInitializeHandshake()`, `registerPending`, `failPending`,
`resolvePending`, `listTools`, `callTool`, and `stop()` unchanged. Delete the now-unused
`source` property references and the old `writeJSONLine`/`LogCenter`-parsing `consumeResponses`.

- [ ] **Step 4: Build the package**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build --package-path .`
Expected: `Build complete!` (fix any leftover references to removed fields).

- [ ] **Step 5: Run the existing stdio tests — they must stay green**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter MCPClientTests`
Expected: PASS — all 7 tests, including `Reconnects after server crash` (proves `onReconnect` → `handleRespawn` still works).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/MCPTransport.swift Sources/AnglesiteCore/StdioTransport.swift Sources/AnglesiteCore/MCPClient.swift
git commit -m "refactor(mcp): extract MCPTransport seam + StdioTransport (no behavior change) (#64)"
```

---

### Task B2: SSE frame parser (pure, no network)

**Files:**
- Create: `Sources/AnglesiteCore/HTTPTransport.swift` (parser first; transport added in B3)
- Test: `Tests/AnglesiteCoreTests/SSEFrameParserTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/SSEFrameParserTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

struct SSEFrameParserTests {
    @Test("Single data line is one payload") func singleDataLine() {
        let payloads = SSEFrameParser.dataPayloads(in: "data: {\"id\":1}\n\n")
        #expect(payloads == ["{\"id\":1}"])
    }

    @Test("event and id fields are ignored; only data is collected") func ignoresNonData() {
        let text = "event: message\nid: 42\ndata: {\"ok\":true}\n\n"
        #expect(SSEFrameParser.dataPayloads(in: text) == ["{\"ok\":true}"])
    }

    @Test("multi-line data is joined with newlines") func multiLineData() {
        let text = "data: line1\ndata: line2\n\n"
        #expect(SSEFrameParser.dataPayloads(in: text) == ["line1\nline2"])
    }

    @Test("multiple events split on blank lines") func multipleEvents() {
        let text = "data: a\n\ndata: b\n\n"
        #expect(SSEFrameParser.dataPayloads(in: text) == ["a", "b"])
    }

    @Test("a trailing event without a final blank line is still emitted") func trailingEvent() {
        let text = "data: a\n\ndata: b\n"
        #expect(SSEFrameParser.dataPayloads(in: text) == ["a", "b"])
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SSEFrameParserTests`
Expected: FAIL — `cannot find 'SSEFrameParser' in scope`.

- [ ] **Step 3: Implement the parser**

```swift
// Sources/AnglesiteCore/HTTPTransport.swift
import Foundation

/// Parses Server-Sent Events framing into the `data:` payloads. MCP Streamable HTTP carries one
/// JSON-RPC message per SSE event. We only need the `data` field; `event:`/`id:`/`retry:` are
/// ignored. A blank line dispatches the accumulated event; a trailing event without a final blank
/// line is still emitted.
enum SSEFrameParser {
    static func dataPayloads(in text: String) -> [String] {
        var payloads: [String] = []
        var dataLines: [String] = []

        func flush() {
            if !dataLines.isEmpty {
                payloads.append(dataLines.joined(separator: "\n"))
                dataLines.removeAll()
            }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("data:") {
                let value = line.dropFirst("data:".count)
                dataLines.append(value.hasPrefix(" ") ? String(value.dropFirst()) : String(value))
            }
            // Other fields (event:, id:, retry:, comments starting with ':') are ignored.
        }
        flush()
        return payloads
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SSEFrameParserTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/HTTPTransport.swift Tests/AnglesiteCoreTests/SSEFrameParserTests.swift
git commit -m "feat(mcp): SSE frame parser for Streamable HTTP responses (#64)"
```

---

### Task B3: `HTTPTransport` over `URLSession` (URLProtocol-stub unit tests)

**Files:**
- Modify: `Sources/AnglesiteCore/HTTPTransport.swift` (add the transport below the parser)
- Test: `Tests/AnglesiteCoreTests/HTTPTransportTests.swift`

- [ ] **Step 1: Write the failing test (stubbed URLSession via URLProtocol)**

```swift
// Tests/AnglesiteCoreTests/HTTPTransportTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

/// A URLProtocol that answers each POST to /mcp from a queue of canned responses, so HTTPTransport
/// is tested without a real server. Responses are matched in FIFO order.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response { let status: Int; let headers: [String: String]; let body: Data }
    nonisolated(unsafe) static var queue: [Response] = []
    nonisolated(unsafe) static var lastRequestBodies: [Data] = []
    nonisolated(unsafe) static var lastSessionHeaders: [String?] = []

    static func reset() { queue = []; lastRequestBodies = []; lastSessionHeaders = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // URLSession strips httpBody for custom protocols unless read via stream; capture both.
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            Self.lastRequestBodies.append(data)
        } else {
            Self.lastRequestBodies.append(request.httpBody ?? Data())
        }
        Self.lastSessionHeaders.append(request.value(forHTTPHeaderField: "Mcp-Session-Id"))

        let r = Self.queue.isEmpty
            ? Response(status: 500, headers: [:], body: Data())
            : Self.queue.removeFirst()
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !r.body.isEmpty { client?.urlProtocol(self, didLoad: r.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct HTTPTransportTests {
    private func makeTransport() -> (HTTPTransport, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let t = HTTPTransport(endpoint: URL(string: "http://127.0.0.1:4399/mcp")!, urlSession: session)
        return (t, session)
    }

    @Test("JSON response is decoded and yielded; session id is captured and replayed") func jsonResponseAndSession() async throws {
        StubURLProtocol.reset()
        // initialize → application/json, sets Mcp-Session-Id
        StubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json", "Mcp-Session-Id": "sess-1"],
            body: #"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#.data(using: .utf8)!
        ))
        // a second request → application/json
        StubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"jsonrpc":"2.0","id":2,"result":{"again":true}}"#.data(using: .utf8)!
        ))

        let (t, _) = makeTransport()
        try await t.open()
        var iterator = t.inbound().makeAsyncIterator()

        try await t.send(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("initialize")]))
        let first = await iterator.next()
        #expect(first == .object(["jsonrpc": .string("2.0"), "id": .int(1), "result": .object(["ok": .bool(true)])]))

        try await t.send(.object(["jsonrpc": .string("2.0"), "id": .int(2), "method": .string("tools/list")]))
        _ = await iterator.next()

        // The second request must carry the session id from the initialize response.
        #expect(StubURLProtocol.lastSessionHeaders == [nil, "sess-1"])
        await t.close()
    }

    @Test("SSE response is parsed into a message") func sseResponse() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "text/event-stream", "Mcp-Session-Id": "sess-9"],
            body: "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"via\":\"sse\"}}\n\n".data(using: .utf8)!
        ))
        let (t, _) = makeTransport()
        try await t.open()
        var iterator = t.inbound().makeAsyncIterator()
        try await t.send(.object(["jsonrpc": .string("2.0"), "id": .int(7), "method": .string("initialize")]))
        let msg = await iterator.next()
        #expect(msg == .object(["jsonrpc": .string("2.0"), "id": .int(7), "result": .object(["via": .string("sse")])]))
        await t.close()
    }

    @Test("202 Accepted yields no message") func acceptedNoBody() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.queue.append(.init(status: 202, headers: [:], body: Data()))
        let (t, _) = makeTransport()
        try await t.open()
        // A notification: send returns without yielding anything.
        try await t.send(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
        await t.close()  // closing finishes the stream; no message expected
        var iterator = t.inbound().makeAsyncIterator()
        let next = await iterator.next()
        #expect(next == nil)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter HTTPTransportTests`
Expected: FAIL — `cannot find 'HTTPTransport' in scope`.

- [ ] **Step 3: Implement `HTTPTransport`** (append to `Sources/AnglesiteCore/HTTPTransport.swift`)

```swift
/// `MCPTransport` over MCP Streamable HTTP. Each `send` POSTs one JSON-RPC message to the `/mcp`
/// endpoint; the response (single `application/json` object, or one-or-more messages over a
/// request-scoped `text/event-stream`) is decoded and funneled into `inbound()`. The session id
/// returned by `initialize` is captured and replayed on every subsequent request. A `404`/refused
/// connection clears the session so a future re-`initialize` can recover (full container-restart
/// recovery lands with #66/#69).
public actor HTTPTransport: MCPTransport {
    public enum HTTPError: Error, Sendable, Equatable {
        case http(status: Int)
        case sessionLost
        case badResponse
    }

    private let endpoint: URL
    private let protocolVersion: String
    private let urlSession: URLSession

    private var sessionID: String?
    private let stream: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation

    public init(
        endpoint: URL,
        protocolVersion: String = "2024-11-05",
        urlSession: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.protocolVersion = protocolVersion
        self.urlSession = urlSession
        (self.stream, self.continuation) = AsyncStream<JSONValue>.makeStream(bufferingPolicy: .unbounded)
    }

    public func open() async throws { /* no persistent connection; first send does the work */ }

    public func send(_ message: JSONValue) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: message.rawValue, options: [])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            sessionID = nil
            throw HTTPError.sessionLost
        }
        guard let http = response as? HTTPURLResponse else { throw HTTPError.badResponse }

        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !sid.isEmpty {
            sessionID = sid
        }

        switch http.statusCode {
        case 202:
            return  // notification accepted; no body
        case 404:
            sessionID = nil
            throw HTTPError.sessionLost
        case 200:
            break
        default:
            throw HTTPError.http(status: http.statusCode)
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/event-stream") {
            let text = String(decoding: data, as: UTF8.self)
            for payload in SSEFrameParser.dataPayloads(in: text) {
                if let value = decode(payload) { continuation.yield(value) }
            }
        } else if data.isEmpty {
            return
        } else {
            if let value = decodeData(data) { continuation.yield(value) }
        }
    }

    public func inbound() -> AsyncStream<JSONValue> { stream }

    public func close() async {
        continuation.finish()
        // Best-effort session teardown; ignore failures.
        if let sessionID {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "DELETE"
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            _ = try? await urlSession.data(for: request)
        }
        sessionID = nil
    }

    private func decode(_ payload: String) -> JSONValue? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return decodeData(data)
    }

    private func decodeData(_ data: Data) -> JSONValue? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return JSONValue.from(raw)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter HTTPTransportTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/HTTPTransport.swift Tests/AnglesiteCoreTests/HTTPTransportTests.swift
git commit -m "feat(mcp): HTTPTransport over Streamable HTTP (#64)"
```

---

### Task B4: `MCPClient.connect(httpEndpoint:)`

**Files:**
- Modify: `Sources/AnglesiteCore/MCPClient.swift`
- Test: `Tests/AnglesiteCoreTests/HTTPTransportTests.swift` (add a client-level case using the stub)

- [ ] **Step 1: Write the failing test (client over a stubbed HTTP server)**

Add to `HTTPTransportTests`:

```swift
    @Test("MCPClient.connect handshakes and lists tools over HTTP") func clientOverHTTP() async throws {
        StubURLProtocol.reset()
        // initialize response
        StubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json", "Mcp-Session-Id": "s"],
            body: #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"0"}}}"#.data(using: .utf8)!
        ))
        // notifications/initialized → 202 (no id, no body)
        StubURLProtocol.queue.append(.init(status: 202, headers: [:], body: Data()))
        // tools/list response
        StubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","description":"E","inputSchema":{"type":"object"}}]}}"#.data(using: .utf8)!
        ))

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)

        let client = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        try await client.connect(httpEndpoint: URL(string: "http://127.0.0.1:4399/mcp")!, urlSession: session)
        let tools = try await client.listTools()
        #expect(tools.first?.name == "echo")
        await client.stop()
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter HTTPTransportTests/clientOverHTTP`
Expected: FAIL — no `connect(httpEndpoint:urlSession:)` member.

- [ ] **Step 3: Add `connect(httpEndpoint:)` to `MCPClient`**

```swift
    /// Connect to an MCP server over Streamable HTTP at `httpEndpoint` (the full `…/mcp` URL) and run
    /// the initialize handshake. Mirrors `start(...)` but for the HTTP transport.
    public func connect(
        httpEndpoint: URL,
        urlSession: URLSession = .shared,
        initializeTimeout: TimeInterval = 10,
        clientName: String = "Anglesite",
        clientVersion: String = "0.1.0"
    ) async throws {
        let t = HTTPTransport(endpoint: httpEndpoint, urlSession: urlSession)
        try await startWithTransport(t, initializeTimeout: initializeTimeout, clientName: clientName, clientVersion: clientVersion)
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter HTTPTransportTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/MCPClient.swift Tests/AnglesiteCoreTests/HTTPTransportTests.swift
git commit -m "feat(mcp): MCPClient.connect(httpEndpoint:) for the HTTP transport (#64)"
```

---

### Task B5: End-to-end against the real plugin server (HTTP mode)

This proves the Swift client interoperates with the actual `StreamableHTTPServerTransport` — the
cross-stack guarantee. Requires Node ≥22 and the bundled plugin; `XCTSkip`-style guarded like
`AppliesEditEndToEndTests`. **Prerequisite:** plugin PR #63 merged and the app's bundled-plugin copy
refreshed (or point at the sibling checkout via `$ANGLESITE_PLUGIN_SRC` / `PluginRuntime`).

**Files:**
- Create: `Tests/AnglesiteCoreTests/MCPClientHTTPEndToEndTests.swift`

- [ ] **Step 1: Write the test**

```swift
// Tests/AnglesiteCoreTests/MCPClientHTTPEndToEndTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

/// Spawns the bundled plugin's MCP server in HTTP mode on a free port and drives the real
/// `MCPClient.connect(httpEndpoint:)`. Skips when Node or the bundled plugin server isn't present.
struct MCPClientHTTPEndToEndTests {
    /// Resolves `server/index.mjs` from the bundled plugin (honors $ANGLESITE_PLUGIN_SRC via PluginRuntime).
    private static func serverScriptURL() -> URL? {
        guard let pluginURL = PluginRuntime.resolve().url else { return nil }
        let s = pluginURL.appendingPathComponent("server/index.mjs")
        return FileManager.default.isReadableFile(atPath: s.path) ? s : nil
    }

    private static func nodeURL() -> URL? {
        for p in ["/usr/local/bin/node", "/opt/homebrew/bin/node", "/usr/bin/node"] {
            if FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return NodeRuntime.bundledExecutableURL
    }

    private static func freePort() -> Int {
        // Bind :0, read the assigned port, close. Small race window is acceptable for a test.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        close(fd)
        return port
    }

    @Test("HTTP end-to-end: connect, list tools, call list_annotations") func httpEndToEnd() async throws {
        guard let node = Self.nodeURL(), let script = Self.serverScriptURL() else {
            // Environment without Node or the bundled plugin — nothing to exercise.
            return
        }
        let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-http-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        let port = Self.freePort()
        let supervisor = ProcessSupervisor()
        let logCenter = LogCenter()
        let handle = try await supervisor.launch(
            source: "mcp-http-e2e",
            executable: node,
            arguments: [script.path],
            environment: [
                "ANGLESITE_MCP_TRANSPORT": "http",
                "ANGLESITE_MCP_HOST": "127.0.0.1",
                "ANGLESITE_MCP_PORT": String(port),
                "ANGLESITE_PROJECT_ROOT": projectRoot.path,
            ],
            currentDirectoryURL: nil,
            restartPolicy: .never,
            attachStdin: false,
            onRespawn: {},
            logCenter: logCenter
        )
        defer { Task { await supervisor.terminate(handle, timeout: 2) } }

        let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let client = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())

        // Poll connect until the server is listening (cold node start can take a moment).
        let deadline = Date().addingTimeInterval(15)
        while true {
            do { try await client.connect(httpEndpoint: endpoint); break }
            catch {
                guard Date() < deadline else { throw error }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { Task { await client.stop() } }

        let tools = try await client.listTools()
        #expect(tools.contains { $0.name == "list_annotations" })

        let result = try await client.callTool(name: "list_annotations", arguments: .object([:]))
        #expect(result.isError == false)
        #expect(result.content.first?.text == "[]")
    }
}
```

- [ ] **Step 2: Run the test (with the plugin available)**

Run: `ANGLESITE_PLUGIN_SRC=../anglesite DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter MCPClientHTTPEndToEndTests`
Expected: PASS when Node + the sibling plugin are present; a clean no-op (early `return`) otherwise.

> If `PluginRuntime.resolve()` doesn't honor `ANGLESITE_PLUGIN_SRC` directly, check how
> `AppliesEditEndToEndTests` resolves the plugin in this repo and mirror it (it uses
> `ANGLESITE_PLUGIN_PATH`). Adjust `serverScriptURL()` accordingly.

- [ ] **Step 3: Commit**

```bash
git add Tests/AnglesiteCoreTests/MCPClientHTTPEndToEndTests.swift
git commit -m "test(mcp): HTTP end-to-end against the real plugin server (#64)"
```

---

### Task B6: Full verification + both build targets

- [ ] **Step 1: Full Core suite**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
Expected: PASS (the new HTTP suites + the unchanged stdio `MCPClientTests`). The unrelated
`AppliesEditEndToEndTests` may no-op/error on a machine whose Node is nvm-only — confirm any failure
is *only* that pre-existing environmental one.

- [ ] **Step 2: DevID app target builds**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: MAS target builds**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit (if any incidental fixes were needed)** — otherwise skip.

---

### Task B7: Open the app PR

- [ ] **Step 1: Push + PR**

```bash
git push -u origin feat/mcp-http-transport-64
gh pr create --base main --title "feat(mcp): HTTP/Streamable transport for MCPClient (#64)" \
  --body "Adds an HTTPTransport to MCPClient behind a new internal MCPTransport seam (StdioTransport preserves today's behavior). Verified end-to-end against the plugin's Streamable HTTP server over localhost. No production call site switches to HTTP yet — that lands with #66/#69. Depends on plugin #63. Closes #64."
```

---

## Self-review notes (for the implementer)

- **Stdio behavior is the safety net.** Task B1 must keep `MCPClientTests` green with zero test
  edits. If a test changes, the extraction wasn't behavior-preserving — fix the transport, not the test.
- **`MCPError` lives on `MCPClient`.** `StdioTransport` throws `MCPClient.MCPError.notInitialized`;
  `HTTPTransport` throws its own `HTTPError`. `MCPClient.sendRequest` propagates whatever the transport
  throws — that's fine (callers already handle thrown errors).
- **No production wiring.** `PreviewSession`/`LocalSiteRuntime` keep calling `start(executable:)`.
  Do not switch any call site to `connect(httpEndpoint:)` in this slice.
