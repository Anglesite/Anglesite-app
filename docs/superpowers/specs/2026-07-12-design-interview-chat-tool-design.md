# Design Interview chat tool wiring (#665) — design note

**Issue:** #665 — wire `DesignInterviewTool` into `FoundationModelAssistant`'s per-conversation
chat tools, completing the third front door deferred out of #631 (GUI sheet and Siri intent
shipped in PR #667).

## The problem

`DesignInterviewTool.init(model:)` needs a conversation-lifetime, mutable,
`@MainActor`-isolated `DesignInterviewModel`. `FoundationModelAssistant` is a plain
(non-`MainActor`) actor whose `conversationTools(for:includeSpotlight:)` builds every other
tool from stateless, window-lifetime dependencies stored at init (`themeCatalog`,
`integrationService`, …). Three constraints shape the answer:

1. `conversationTools` is synchronous and called from two synchronous paths
   (`makeSession(context:includeSpotlight:)` and `trimSessionIfNeeded(current:context:)`).
   Making it `async` ripples through session construction and the trim path.
2. `trimSessionIfNeeded` rebuilds the tool array mid-conversation (#456). Any design that
   constructs a *fresh* interview model per tool-array build silently resets an in-flight
   interview when the transcript gets trimmed.
3. The GUI sheet binds `.sheet(item: $model.designInterviewModel)` (`SiteWindow.swift`), so
   sharing `SiteWindowModel`'s instance with chat would pop the sheet open mid-chat — and
   would couple `AnglesiteCore` to app-layer window state.

## Decision: actor-cached lazy provider

- **`DesignInterviewTool`** gains a provider-based initializer,
  `init(provider: @escaping @Sendable () async -> DesignInterviewModel)`, alongside the
  existing `init(model:)` (which becomes a trivial wrapper). `call` awaits the provider each
  turn. Awaiting is free for the direct-model case and gives the chat path its lazy hook.
- **`FoundationModelAssistant`** gains an optional init dependency,
  `designInterviewFactory: (@Sendable () async -> DesignInterviewModel)? = nil`, plus actor
  state `private var designInterviewModel: DesignInterviewModel?`. An internal
  `currentDesignInterviewModel()` lazily invokes the factory once and caches (with an
  actor-reentrancy re-check after the `await`, first-writer-wins). `conversationTools`
  stays synchronous: when a factory is present it appends
  `DesignInterviewTool(provider: { [weak self] … })`, where the provider calls back into
  the actor. The capture is weak because the actor retains the session, the session retains
  its tools, and a strong capture would close a self-retain cycle.
- **Lifetime: one interview per chat session.** The cached model survives session trims
  (constraint 2) and is cleared by `resetSession()` — resetting the chat also starts a
  fresh interview, matching the user-visible meaning of "reset". `cancel()` does not clear
  it. The chat interview is deliberately a *separate* conversation from the GUI sheet's
  (constraint 3): each front door owns its own `DesignInterviewModel`, exactly as
  `presentDesignInterview()` already builds a standalone one per sheet presentation.
- **App wiring.** `SiteAssistantSessionFactory.makeSession` gains a `packageURL: URL?`
  parameter (`SiteWindowModel` passes `site.packageURL`). The factory closure mirrors
  `presentDesignInterview()`: `SiteBusinessType.read` for the business type, a **standalone**
  `FoundationModelAssistant(tier: .onDevice)` as the interview's assistant (the interview is
  its own model conversation, not turns appended to the hosting chat session — and using the
  hosting actor would re-enter its single-flight session mid-drain), and
  `AnglesitePackage(url: packageURL)`. `AssistantBuilder` grows a matching
  `designInterviewFactory` parameter threaded into `FoundationModelAssistant`.
- `attachedToolNames` advertises `DesignInterviewTool.toolName` when a factory is present,
  so the chat UI's `.started` event reflects the wiring like every other optional tool.

## Alternatives rejected

- **Share `SiteWindowModel.designInterviewModel` across front doors** — pops the GUI sheet
  from a chat turn (sheet(item:) binding) and inverts the layering (core actor reaching
  into app window state).
- **Fresh model per session build (async `conversationTools`)** — resets in-flight
  interviews on transcript trim; async ripple through `makeSession`/`trimSessionIfNeeded`.

## Testing

All new behavior is testable without the live on-device model:

- `DesignInterviewTool` provider init: `call` routes the message into the provided model
  (fake `ConversationalAssistant`) and returns the model's last transcript entry; the
  `designForMe` fast path works through the provider too.
- `FoundationModelAssistant.currentDesignInterviewModel()`: lazy (factory not invoked until
  first call), cached (same instance across calls, factory invoked once), and reset
  (`resetSession()` clears it; next call builds a new instance).
- `attachedToolNames` (internal-for-testing, same pattern as `instructions`/`turnPrompt`):
  includes `designInterview` only when a factory is supplied.

Hosted-app-target wiring (`SiteAssistantSessionFactory`/`SiteWindowModel`) stays thin per
the CLAUDE.md CI policy; the testable logic lives in `AnglesiteCore`.
