# Repo Bootstrap for Non-Git Sites — Design (#68)

**Date:** 2026-06-20
**Issue:** [#68](https://github.com/Anglesite/Anglesite-app/issues/68) · part of the Containerization epic [#59](https://github.com/Anglesite/Anglesite-app/issues/59)
**Status:** Approved design — ready for implementation plan

## Problem

Git is the source of truth on every platform, so both container runtimes (#66 remote, #69 local)
**hydrate by `git clone`**. A site created in-app may have a local `Source/` git repo (the scaffolder
runs `git init`) but **no remote** to clone from. Before any containerized preview can work, such a
site needs a remote repository it can be cloned out of.

This sub-project delivers a deliberate, one-tap **"Publish to GitHub"** action that creates a private
GitHub repository and pushes `Source/` to it. It unblocks #66 and #69 and has standalone value today
(a one-step path from a local site to a backed-up, clonable GitHub repo) on the DevID build.

## Scope

In scope:
- Detect whether a site's `Source/` repo already has a remote.
- One-tap create-and-push: `git init` (if absent) + initial commit (if needed) + create the remote
  repo + wire `origin` + push.
- Surface it as an explicit owner-invoked action in the app, with progress and the resulting URL.
- Default visibility **private**; provider **GitHub** only.
- A `RepoProvider` protocol seam so a token/REST implementation can be added for MAS/iOS later
  without reworking callers.

Explicitly out of scope (deferred):
- A GitHub REST / BYO-token provider for MAS and iOS — tracked with #71. Only the seam is built now.
- Auto-remediation when a runtime can't hydrate — #66/#69 don't exist yet, so wiring it now would be
  dead code. `RepoBootstrap`'s API is shaped so those runtimes call it when they land.
- Non-GitHub providers (GitLab, generic remotes).
- Caching the repo URL in `Config/settings.plist` — published state is derived from the git remote
  (see §5). Caching can be added later if a read-`origin`-on-open cost ever matters.

## Design decisions (from brainstorming)

| Decision | Choice | Rationale |
|---|---|---|
| Credential path | **`gh` now, REST seam later** | Reuses the existing `GitHubAuthFlow` credential store; `gh` already owns GitHub creds per CLAUDE.md. A `RepoProvider` protocol keeps MAS/iOS (#71) open. |
| Trigger | **Explicit one-tap action** | Matches the issue's "one-tap" wording; avoids pushing throwaway scratch sites to GitHub; honest today since no runtime exists to auto-remediate. |
| Default visibility | **Private** | Safe default for an owner's unpublished work; the user can change it on GitHub. |
| Name collision | **Surface gh's error** (no silent auto-suffix) | Predictable; the owner stays in control of the repo name. |
| Published state | **Git remote is the source of truth** | No new persisted field; derive by reading `origin`. |

## Architecture

### `RepoBootstrap` (AnglesiteCore actor)

Modeled directly on `GitHubAuthFlow`:
- An injectable launcher/runner seam so unit tests drive the flow with fixture output instead of
  spawning real `gh`/`git`.
- Production runs `git` and `gh` through `ProcessSupervisor`, streaming combined stdout/stderr into
  the Debug pane via `LogCenter` (logs are sacred — no `>/dev/null`).
- Emits lifecycle events for the UI.

```swift
public actor RepoBootstrap {
    public enum Event: Sendable, Equatable {
        case progress(step: Step, message: String)
        /// gh needs the device-code flow; UI shows the prompt (reuse GitHubAuthSheetView).
        case needsAuth(verificationURL: URL, userCode: String)
        case published(RemoteRepo)
        case failed(reason: String)
    }
    public enum Step: Sendable { case checkingRemote, initializing, committing, creatingRepo, pushing }

    public func publish(siteSourceDirectory: URL, repoName: String, isPrivate: Bool) -> AsyncStream<Event>
    public func remote(of siteSourceDirectory: URL) async -> RemoteRepo?  // nil ⇒ not yet published
}
```

### `RepoProvider` seam

```swift
public struct RemoteRepo: Sendable, Equatable {
    public let url: URL          // browser/clone URL
    public let owner: String
    public let name: String
}

public protocol RepoProvider: Sendable {
    /// Create the remote repo, wire `origin` in `source`, and push. Throws with a user-facing reason.
    func createAndPush(name: String, isPrivate: Bool, source: URL) async throws -> RemoteRepo
}

struct GHRepoProvider: RepoProvider { /* gh repo create … --source --remote=origin --push */ }
// Deferred (#71): GitHubRESTRepoProvider — BYO token, works on MAS/iOS.
```

`RepoBootstrap` owns the git-side preflight (init / commit / detect remote); the `RepoProvider`
owns only the create-remote-and-push step, which is the part that differs between `gh` and REST.

## Flow (gh path)

1. **Detect remote** — `git -C <Source> remote get-url origin`. Exit 0 ⇒ already published; the action
   relabels to **"View on GitHub"** (opens the URL) and skips the rest.
2. **Ensure committable** — `git init` if `.git` is absent (the scaffolder usually did this, but the
   action must be self-sufficient). Stage all and `git commit` if there are no commits or a dirty tree.
   Reuse the `GitInit`/`CommandRunner` seam style already in `SiteScaffolder`.
3. **Create + push** — `GHRepoProvider`:
   `gh repo create <name> --private --source=<Source> --remote=origin --push`.
   One invocation creates the GitHub repo, wires `origin`, and pushes the default branch.
   - Repo name defaults to the sanitized site display name.
   - If `gh` is not authenticated, its output triggers the device-code flow; `RepoBootstrap` emits
     `.needsAuth(...)` and the UI presents `GitHubAuthSheetView`, then retries.
   - On name collision, surface gh's error verbatim as `.failed(reason:)`.
4. **Settle** — `.published(RemoteRepo)` (parsed from gh's output / `git remote get-url origin`) or
   `.failed(reason:)`.

## UI

- **`PublishModel`** (`@State` on `SiteWindow`), a peer of `DeployModel`, owning the `RepoBootstrap`
  lifecycle for the window's site.
- **`PublishSheet`** — progress line per `Step`, the device-code prompt when `gh` needs auth (reusing
  `GitHubAuthFlow` + `GitHubAuthSheetView`), and the final repo URL with a "View on GitHub" button.
- **Toolbar action "Publish to GitHub…"** next to Deploy. Collapses to **"View on GitHub"** once a
  remote exists (state read on window open via `RepoBootstrap.remote(of:)`).
- The action and its model are wrapped `#if !ANGLESITE_MAS`, matching the existing `gh` UI gating
  (`GitHubAuthSheetView`). The `RepoProvider` seam is the documented extension point for MAS/iOS.

## State / source of truth

The **git remote (`origin`) is the source of truth** for published state. No new persisted field is
introduced. On window open, `RepoBootstrap.remote(of:)` reads `origin` (cheap) to decide the toolbar
label. This keeps the app from becoming a second source of truth and survives the site being cloned,
moved, or edited outside the app.

## Testing

`RepoBootstrapTests` (Swift Testing, `AnglesiteCoreTests`), driven by a fake launcher — no real
`gh`/`git`:
- no remote → runs create+push, settles `.published`.
- existing remote → short-circuits, no create call.
- no commits / dirty tree → commits before push.
- `gh` not authenticated → emits `.needsAuth`, then proceeds after auth.
- name collision → `.failed` carrying gh's error text.
- `remote(of:)` → returns parsed `RemoteRepo` when `origin` is set, `nil` otherwise.

UI (`PublishModel`/`PublishSheet`) lives in the app target and is kept thin, with all branching logic
in `RepoBootstrap` — per the CLAUDE.md note that hosted-app tests don't run on CI runners, so testable
logic must live in `AnglesiteCore`.

## Risks / open points

- **gh availability on DevID** — `gh` must be on `PATH`; `GitHubAuthFlow` already locates it the same
  way. If absent, `.failed` with an actionable "install gh" message.
- **Default branch name** — push relies on gh/git's configured default (`main`). No assumption beyond
  what `git init` produces locally.
- **MAS/iOS** — intentionally unsupported now; the seam exists so #71 adds `GitHubRESTRepoProvider`
  without touching `RepoBootstrap`'s git preflight or the call sites.
