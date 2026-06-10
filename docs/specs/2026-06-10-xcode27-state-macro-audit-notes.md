# Xcode 27 / SwiftUI 27 `@State`-macro audit notes

Date: 2026-06-10
Scope: issue #108
Toolchain: Xcode 27.0 (27A5194q), Swift 6.4 (swiftlang-6.4.0.20.104)

## Context

SwiftUI 27 reshapes `@State` as a macro. Classes stored in `@State` now initialize **lazily** — once per view lifetime, at first access — instead of eagerly inside the view struct's initializer. The behavioral edge: any `@State`-stored reference type whose initializer has side effects (spawns work, registers observers, allocates dependencies via a default argument) may now initialize *later* than it did under Xcode 26's eager semantics. The state graph still wins on the actual stored value, but the *moment* of construction shifts.

This note inventories every `@State`-stored class in the app and records the audit verdict for each.

References:
- ["What's new in SwiftUI", WWDC26 session 269](https://developer.apple.com/videos/play/wwdc2026/269/)
- ["What's new in Xcode 27", WWDC26 session 258](https://developer.apple.com/videos/play/wwdc2026/258/)

## Inventory

`grep -rn '@State.*var' Sources/AnglesiteApp/` for class-typed bindings only (value types — `String`, `Bool`, enums, optionals of value types — are unaffected by the macro change). One entry per `@State`-stored reference type.

| Site | Type | Init signature | Side effects? |
|---|---|---|---|
| `SiteWindow.swift:26` | `PreviewModel` (`@MainActor @Observable`) | `init(runtime: any SiteRuntime = LocalSiteRuntime())` | **Yes** — default-arg evaluation allocates `LocalSiteRuntime`; body allocates `MCPApplyEditRouter` and spawns an observe `Task`. |
| `SiteWindow.swift:27` | `DeployModel` (`@MainActor @Observable`) | synthesized memberwise (no explicit init) | No — pure assignment to stored defaults. |
| `SiteWindow.swift:29` | `ChatModel?` (`@MainActor @Observable`) | n/a — optional, set later by `SiteWindow.loadAndStart` | No — wrapper holds `nil` at view construction; the init that runs is gated on user action. |
| `SiteWindow.swift:32` | `HealthModel` (`@MainActor @Observable`) | `public init(runner: any HealthCheckRunner)` | No — single property assignment; `DefaultHealthCheckRunner()` default-arg is itself trivial. |
| `AnglesiteApp.swift:38` | `Updater` (`@StateObject`) | n/a — `@StateObject`, not `@State` | n/a — `@StateObject` is unaffected by the `@State` macro change. |

`NewSiteWizardModel` and `SiteScaffolder` are also stored as `@State` optionals (`SitesLauncherView.swift:24-25`) — same gating as `ChatModel?`.

## Verdict per site

### `PreviewModel` — only site with init-time side effects

```swift
init(runtime: any SiteRuntime = LocalSiteRuntime()) {
    self.runtime = runtime
    self.editRouter = MCPApplyEditRouter(mcpClient: { [weak runtime] in
        await runtime?.mcpClient
    })
    Task { @MainActor [weak self] in
        for await newState in await runtime.observe() {
            self?.state = newState
        }
    }
}
```

The init allocates a runtime, builds an edit router, and spawns an observe `Task`. All three are deferred by the macro change.

**Verdict: safe, and in fact an improvement.**

The only `PreviewModel` access path inside `SiteWindow` is `preview.open(...)` from `loadAndStart`, which fires inside `.task { ... }` — *after* first body evaluation. So lazy initialization runs comfortably before any consumer reads `preview.state`, `preview.editRouter`, or invokes `preview.open`.

The lazy semantics also *close a small leak*. Under eager `@State`:

1. SwiftUI reconstructs the `SiteWindow` struct on every state change in the parent.
2. Each reconstruction calls `_preview = State(wrappedValue: PreviewModel())`, allocating a fresh `PreviewModel`.
3. SwiftUI discards the new wrapper and substitutes the state-graph value — but the *throwaway* `PreviewModel`'s init already ran, including the `Task { for await newState in await runtime.observe() ... }`.
4. That Task captures `runtime` strongly (no `[weak runtime]`). So the throwaway `LocalSiteRuntime` actor stays alive as long as the Task is iterating its `AsyncStream` — i.e. indefinitely.

Multi-window doesn't aggravate this (one `PreviewModel` per window is the design), but parent state churn during a window's lifetime would. With the `@State` macro, the constructor runs once, no throwaways, no orphaned runtimes.

No code change required.

### `DeployModel` — pure assignment

The synthesized memberwise init only assigns to `phase`, `logLines`, `drawerPresented`, `blockedPresented`, `tokenPromptPresented`. No allocations beyond the default-initialized value types, no `Task`, no `Notification` registration. Lazy or eager makes no difference.

### `HealthModel` — single assignment

```swift
public init(runner: any HealthCheckRunner) {
    self.runner = runner
}
```

`DefaultHealthCheckRunner()` (the `SiteWindow.swift:32` default arg) is a trivial struct init. No observers registered, no Tasks spawned. Lazy or eager makes no difference.

### `ChatModel?`, `NewSiteWizardModel?`, `SiteScaffolder?` — gated by user action

Stored as `@State Optional<T>`. The wrapper holds `nil` at construction; the contained type's `init` only runs when the view explicitly assigns a value (`SiteWindow.loadAndStart` for `ChatModel`, the New Site flow for the wizard/scaffolder). These were already "lazy" in spirit; the macro change is a no-op for them.

### `Updater` — `@StateObject`

`@StateObject`'s lazy semantics predate the `@State` macro (it has always initialized on first body evaluation, not at struct construction). Unaffected.

## Net result

**No code changes required.** Every `@State`-stored class is either side-effect-free at init, gated behind an optional, or accessed only after first body evaluation. The macro's lazy semantics happen to *fix* a latent leak in `PreviewModel`/`SiteWindow` interaction; that's a free win.

## Items not in scope here

- `ViewBuilder` → `ContentBuilder` migration diagnostics: see `swift build` warning output captured under the build/test verification half of #108 (separate PR).
- New deprecations introduced in Xcode 27 SDKs: same.
