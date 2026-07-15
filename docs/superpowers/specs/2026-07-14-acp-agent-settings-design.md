# ACP agent connections — Settings tab + active-backend selection

**Date:** 2026-07-14
**Status:** Design (no implementation yet)
**Issue:** none yet — new feature, related to the Claude Code removal epic #459 and the
cross-platform port's `ExternalLLMBackend` (#571 P5), but a distinct integration (see §1)
**Related:** [`2026-07-08-cross-platform-swift-port-design.md`](2026-07-08-cross-platform-swift-port-design.md) §8,
[`2026-06-20-claude-code-removal-roadmap-design.md`](2026-06-20-claude-code-removal-roadmap-design.md)

---

## 1. Scope

Add a Settings tab where the user can register connections to arbitrary **ACP (Agent Client
Protocol)** agents — Zed's JSON-RPC protocol for editor↔agent communication — and pick which
one (or Apple Intelligence on-device) is the app's active assistant backend. This slice covers
**configuration and connection plumbing only**: the Settings UI, credential storage, the
`ACPClient`/transport layer, the container-exec extension it depends on, and wiring the result
into the existing `ContentAssistantFactory`/`ConversationalAssistant` seam so the selection is
real. It does **not** include a new chat/session UI or tool-call permission prompts — those are
a follow-up slice once this seam exists (decided during brainstorming).

**Relationship to existing docs, for anyone cross-referencing:** the cross-platform port design
(§8) already plans an `ExternalLLMBackend` — a `URLSession`-based backend speaking an
OpenAI-style chat-completions HTTP protocol against a user-configured endpoint. That is a
simpler, HTTP-only, non-tool-calling backend, still unimplemented and still worth building
independently for plain self-hosted/hosted chat endpoints (Ollama, llama.cpp, hosted APIs
without ACP support). This spec is a **different, additive** integration: ACP is
session-oriented and supports tool-call/permission negotiation, and connections here include a
local-subprocess transport that `ExternalLLMBackend` never needed. Both can coexist as sibling
`ConversationalAssistant` conformers.

**Confirmed via research, not aspirational:** `ClaudeAgent` and `claude --print` are already
fully removed from `Sources/` — this feature is additive to a Foundation-Models-only baseline,
not a replacement for anything currently wired up.

## 2. Decisions (settled during brainstorming)

| Decision | Choice |
|---|---|
| Use case | Not committed to one consumer yet — build the connection/config plumbing generically; content-help/chat is the first consumer via the existing seam. |
| Transport | Both: local stdio subprocess **and** remote network. This slice builds HTTP (+SSE for push); WebSocket is a fast-follow only if a real agent needs it (§4.3). |
| Agent capability | Full agentic access (tool calls / file edits) scoped to the open site's `Source/` repo — not chat-only. |
| Local execution location | Inside the site's existing container, alongside the dev server and MCP sidecar — not a host `ProcessSupervisor` subprocess. |
| UI scope this slice | Settings + plumbing only. No chat/session panel, no tool-permission UI yet. |
| Selection scope | Global (app-wide Settings), not per-site. |
| Multiplicity | Multiple named connections can be registered; one is picked as active. |

## 3. Baseline this builds on

- **Settings tabs** (`Sources/AnglesiteApp/SettingsView.swift:7-15`): a `TabView` with General,
  Siri AI, and Advanced. Each tab is a private `View` reading `@AppStorage(AppSettings.Key...)`
  bound to keys declared in `AppSettings.Key` (`Sources/AnglesiteCore/AppSettings.swift:14-36`).
  `AdvancedSettingsView` (`SettingsView.swift:60-188`) is the closest existing shape: per-topic
  `Section`s, credential rows via `KeychainTokenRow` (`SettingsView.swift:232-435`).
- **Chat backend seam:** `ChatModel` depends on `any ConversationalAssistant`
  (`Sources/AnglesiteCore/ConversationalAssistant.swift:69`), which refines `ContentAssistant`
  (`Sources/AnglesiteCore/ContentAssistant.swift:20`). `ContentAssistantFactory.make(tier:)`
  (`Sources/AnglesiteCore/ContentAssistantFactory.swift`) is today's single point that resolves a
  backend, and it currently always returns `FoundationModelAssistant` (or `nil` when
  `FoundationModels` isn't compiled in). The actual per-site composition happens in
  `SiteAssistantSessionFactory.Dependencies.assistant`
  (`Sources/AnglesiteApp/SiteAssistantSessionFactory.swift:58-78`), which builds
  `CombinedAugmentedAssistant(base: FoundationModelAssistant(tier: .onDevice, ...), ...)` — this
  is the exact closure where an alternate `base` gets substituted.
- **`AssistantEvent`** (`ConversationalAssistant.swift:8-27`) already models `toolUse`/
  `toolResult` cases with a "provider-neutral id: label" deliberately chosen so a subprocess-style
  backend can populate the chat surface without special-casing — i.e. the event vocabulary this
  spec's `ACPAssistant` needs already exists and doesn't need new cases.
- **Secrets:** `SecretStore` protocol + `SecretAccounts` enum
  (`Sources/AnglesiteCore/Platform/SecretStore.swift`), Darwin-backed by `KeychainStore`
  (`SecItem`, service `io.dwk.anglesite`). Cloudflare/GitHub tokens are the existing precedent
  (`readCloudflareToken()`/`writeCloudflareToken()`/`clearCloudflareToken()`, lines 40-52).
- **MCP transport precedent:** `MCPTransport` protocol (`Sources/AnglesiteCore/MCPTransport.swift:9`)
  with `StdioTransport` (host `ProcessSupervisor`-backed, `attachStdin: true`) and `HTTPTransport`
  (MCP Streamable HTTP, bearer token, SSE) conformers, both consumed by `MCPClient`. **Important
  distinction found during research:** `StdioTransport` spawns on the **host** via
  `ProcessSupervisor` — it is not container-exec-based. The MCP sidecar itself, which does run
  inside the container, is reached over `HTTPTransport` via the vsock→TCP proxy
  (`LocalContainerSession.mcpURL`). So neither existing `MCPTransport` conformer is a direct fit
  for "run this local ACP agent inside the container" — that needs a new transport (§4.3).
- **Container exec:** `LocalContainerControl.exec(siteID:argv:environment:workingDirectory:onOutput:)`
  (`Sources/AnglesiteCore/LocalContainerControl.swift:82-88`) is a generic "run arbitrary argv
  inside this site's running container" call, already exercised in production for `git`, `npm
  run build`, `pre-deploy-check.sh`, and `wrangler deploy` (`ContainerDeployExecutor`,
  `Sources/AnglesiteCore/DeployExecutor.swift`). Its production conformer,
  `ContainerizationControl.exec` (`Sources/AnglesiteContainer/ContainerizationControl.swift:468-534`),
  wires `stdout`/`stderr` via Apple's `LinuxProcessConfiguration` but not `stdin`, and is a
  wait-to-completion call (`runToCompletion`, line 675); `runDetached` (line 722) fires-and-forgets
  with no returned handle. Apple's `LinuxProcessConfiguration` already exposes a `stdin:
  ReaderStream?` field (`.build/checkouts/containerization/.../LinuxProcessConfiguration.swift:366-370`),
  so a bidirectional, held-open exec is an additive extension of this existing seam, not new
  vsock/vminit plumbing.

## 4. Design

### 4.1 Data model & storage

```swift
public struct ACPAgentConnection: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var transport: Transport

    public enum Transport: Codable, Sendable, Equatable {
        case stdio(command: String, arguments: [String])
        case remote(url: URL)
    }
}
```

Non-secret fields (`id`, `name`, `transport`) live in a new `ACPAgentStore`
(`AnglesiteCore`), a small JSON-file-backed store mirroring `SiteStore`'s `recents.json`
pattern — a better fit than `AppSettings`'s scalar `@AppStorage` keys, which aren't meant for
structured lists. File location: `~/Library/Application Support/Anglesite/acp-agents.json`
(non-MAS) / the app's sandboxed Application Support container (MAS) — same directory class
`SiteStore` already uses, so no new sandbox entitlement is needed.

Secrets (a bearer token for `.remote` connections) go through `SecretStore`: add
`SecretAccounts.acpAgentToken(id: UUID) -> String` (an account-key function, not a constant,
since there can be many) plus `readACPAgentToken(id:)`/`writeACPAgentToken(id:)`/
`clearACPAgentToken(id:)` extension methods on `SecretStore`, following the existing
Cloudflare/GitHub extension-method shape. `.stdio` connections have no credential — the
in-container process inherits no ambient secrets by default (out of scope: passing arbitrary
env vars to a stdio agent; can follow if a real agent needs it).

One new scalar key on `AppSettings`: `activeAssistantBackend: String`, values
`"foundationModels"` (default) or `"acp:<agent-UUID>"`. Plain string rather than a stored enum,
matching every other `AppSettings` key's style.

### 4.2 Settings UI

A 4th tab in `SettingsView.swift`, **"Agents"** (`Label("Agents", systemImage: "network")`),
between Siri AI and Advanced:

- **"Active Model" section:** a `Picker` bound to `activeAssistantBackend`, listing "Apple
  Intelligence (On-Device)" plus each `ACPAgentStore` entry by name. Selecting an entry whose
  connection is currently unreachable doesn't block the picker — see §4.5 for fallback
  behavior.
- **"ACP Agents" section:** list of configured connections (name + one-line transport summary,
  e.g. "Local · `claude-code-acp`" or "Remote · https://…"), each with Edit/Remove. "Add
  Agent…" opens a sheet: name field, a segmented transport-type control (Local / Remote), then
  either command + space-separated-arguments fields (Local) or a URL field + a `KeychainTokenRow`
  for the bearer token (Remote). A "Test Connection" button (§4.5) runs before the sheet can
  save, mirroring `KeychainTokenRow`'s existing verify-then-persist shape.

Reuses `KeychainTokenRow` as-is for the remote credential field; no changes needed to that view.

### 4.3 ACP protocol client & transport

New types in `AnglesiteCore`, mirroring the `MCPClient`/`MCPTransport` split:

```swift
public protocol ACPTransport: Sendable {
    func open() async throws
    func send(_ message: JSONValue) async throws
    func inbound() -> AsyncStream<JSONValue>
    func close() async
}
```

Two conformers:

- **`ACPContainerExecTransport`** (local/stdio connections): calls a new
  `LocalContainerControl.execInteractive(siteID:argv:environment:workingDirectory:) async throws
  -> InteractiveExecHandle` — the extension identified in §3 — where `InteractiveExecHandle`
  exposes `write(_ data: Data) async throws` (feeds the process's `stdin`) alongside the existing
  `onOutput` callback and a `terminate()`. This is new surface on `LocalContainerControl` /
  `ContainerizationControl`, not a new vsock listener: it wires the same `LinuxProcessConfiguration`
  that `exec` already builds, adding its unused `stdin` field and returning a live handle instead
  of awaiting completion.
- **`ACPHTTPTransport`** (remote connections): same shape as `HTTPTransport.swift` — POSTs
  framed JSON-RPC to the configured URL with the Keychain-stored bearer token, and reads
  server-pushed `session/update` notifications over a `text/event-stream` response, matching
  `HTTPTransport`'s existing SSE handling for MCP. This is the only remote transport built in
  this slice. A dedicated WebSocket transport is a fast-follow, added only if a real remote ACP
  agent requires full-duplex push that SSE-over-HTTP can't express — `ACPTransport` is the seam
  a `ACPWebSocketTransport` would plug into later without touching `ACPClient`.

`ACPClient` (mirrors `MCPClient`): owns id-correlation and the ACP handshake
(`initialize` → `session/new`), independent of which transport it's given. JSON-RPC message
framing (newline-delimited JSON) is conceptually identical to what `StdioTransport`/`HTTPTransport`
already do for MCP; if a shared encode/decode helper doesn't already exist as a standalone
function, extracting one is a nice-to-have at implementation time, not a blocker.

### 4.4 Backend seam integration

New `ACPAssistant: ConversationalAssistant`, constructed with an `ACPClient` and the site's
`AssistantContext`. Its `converse(prompt:context:)` maps ACP `session/update` notifications onto
`AssistantEvent` cases — `toolUse`/`toolResult` already exist for exactly this. `generate` (the
`ContentAssistant` base method) wraps a single-turn `converse` call, matching how a non-streaming
caller already treats `FoundationModelAssistant`.

A new `AssistantBackendResolver` (`AnglesiteCore`) reads
`AppSettings.shared.activeAssistantBackend` and either returns the existing
`FoundationModelAssistant` path or constructs an `ACPAssistant` from the matching
`ACPAgentStore` entry — kept separate from `ContentAssistantFactory` (which resolves a
`FoundationModelTier`, a different axis) rather than overloading it with backend selection.

**Amendment (post-implementation, 2026-07-15):** as built, `SiteAssistantSessionFactory.makeSession`
resolves `resolveActiveACPAssistant(...) ?? dependencies.assistant(...)` — when an ACP agent is
active, the resolver's `ACPAssistant` replaces the *entire* assistant, not just the `base:` inside
`CombinedAugmentedAssistant`. This means an active ACP agent does **not** get the FoundationModels
RAG/knowledge-index augmentation or emit `.citations` chips — a deliberate divergence from this
section's original wording, confirmed during the final whole-branch review. Rationale: an ACP
agent (e.g. one backed by a coding-assistant CLI) typically has its own filesystem/tool access
inside the container and reads the site's content directly, so injecting FoundationModels-oriented
RAG context would be redundant or actively confusing context to hand it. If a future ACP agent
integration needs RAG-style grounding, revisit this at that point rather than retrofitting it
speculatively now.

### 4.5 Error handling

- **In-container stdio agent:** process stdout/stderr flows to the debug pane via the same
  `onOutput`/`LogCenter` path every other container-exec'd process already uses ("logs are
  sacred"). A crashed/exited process surfaces as `AssistantEvent.backendExited(code:)`, which
  `ChatModel` already has a case for.
- **Remote agent:** the Settings sheet's "Test Connection" calls `ACPClient.initialize()` once
  before allowing Save, surfacing failure inline (reusing `KeychainTokenRow.VerifyOutcome`'s
  success/failure shape). A later runtime failure (token revoked, endpoint down) surfaces the
  same way a `FoundationModelAssistant` unavailability does today.
- **Active-but-unreachable agent:** the resolver falls back to returning `nil` for that backend,
  matching `ContentAssistantFactory`'s existing "Foundation Models not compiled in" `nil` case —
  consumers (`ChatModel`, etc.) already handle a `nil` assistant. The Settings picker still shows
  the agent as selected (state is honest), but functional consumers degrade gracefully rather
  than crashing.

### 4.6 Testing

- `ACPAgentStore`: Codable round-trip + CRUD unit tests, Swift Testing, mirroring `SiteStoreTests`.
- `ACPClient` + `ACPHTTPTransport`: unit tests against a fake JSON-RPC-speaking process (stdio)
  and a mocked `URLSession` (remote), mirroring `MCPClientTests`/`MCPClientHTTPEndToEndTests`.
- `LocalContainerControl.execInteractive` extension: gated behind `ANGLESITE_CONTAINER_TESTS=1`
  like existing container tests, exercising a real bidirectional echo process inside a booted
  container.
- Settings "Agents" tab: manual GUI smoke (add/edit/remove a connection, switch active model,
  Test Connection success/failure), matching how other Settings tabs are verified today — no
  automated UI test infra exists for this surface.

## 5. Out of scope (explicit)

- Chat/session UI for actually conversing with an ACP agent or approving its tool-call requests
  (follow-up slice).
- Per-site backend override (global-only this slice).
- `ExternalLLMBackend` (cross-platform port §8) — separate, simpler HTTP chat-completions
  backend; not built or modified here.
- Passing arbitrary environment variables/secrets into a `.stdio` agent's container process.
- WebSocket transport implementation detail (may resolve to HTTP+SSE at implementation time).
