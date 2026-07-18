# Publish to GitHub: re-enable for MAS (issue #654 follow-up)

## Context

Issue #654 tracked moving "Publish to GitHub" (`RepoBootstrap`) off `/usr/bin/git` and the `gh`
CLI, both of which are non-viable under the MAS App Sandbox. That plumbing has already landed:

- PR #663 moved the git preflight (init/commit/status) to in-process SwiftGit2.
- PR #659 added SwiftGit2 push + an app-owned GitHub token Keychain slot (`SecretAccounts.gitHubToken`).
- PR #779 added `HTTPRepoProvider` (GitHub REST `POST /user/repos` + SwiftGit2 `addRemote`/`push`)
  and wired it into `RepoBootstrap.live()` for every Darwin build (`#if canImport(Darwin)`, not
  `ANGLESITE_MAS` — so both the (retired) direct-download config and MAS pick it up identically).

PR #779 explicitly flagged what it didn't do: the "Publish to GitHub" UI (toolbar item, Site menu,
`PublishSheet`) is still compiled out of the MAS build via `#if !ANGLESITE_MAS`, so **no user of the
shipping app can reach this feature at all**. This spec covers that remaining UI-wiring gap, closing
out #654.

### The `.needsAuth` bug this also fixes

Digging into the gated code surfaced a second, independent bug. Today `.needsAuth` (from
`RepoBootstrap`, meaning `HTTPRepoProvider.isAuthenticated()` returned false) routes to
`GitHubAuthSheetView`, which drives `GitHubAuthFlow` — a `gh auth login --web` subprocess. `gh`
writes the resulting token into its *own* credential store via `git-credential-osxkeychain`.
`HTTPRepoProvider`, however, reads the token from the app's own Keychain slot
(`SecretAccounts.gitHubToken`, via `InProcessGit.defaultTokenProvider`). These are two different
credential stores. So even where this code path compiles, a successful `gh auth login` does not
satisfy `HTTPRepoProvider.isAuthenticated()` — `.needsAuth` fires again, forever. Confirmed dead:
`ANGLESITE_MAS` is defined for every current build config (`project.yml`'s Xcode scheme *and*
`Package.swift:238`'s `AnglesiteAppCore` target), so this loop has never actually run under CI or
the shipping app — but it would loop if reached.

Separately, a working, MAS-gated replacement for the credential side already exists and is unused
outside MAS: `SettingsView.swift`'s `KeychainTokenRow`-based GitHub row, wired to
`SecretAccounts.gitHubToken` and `GitHubAPITokenVerifier`. `HTTPRepoProvider`'s own error message
(`HTTPRepoProvider.swift:93`) already tells the user to use it: *"add one in Settings → Advanced →
Credentials."*

## Goal

Make "Publish to GitHub" reachable and working end-to-end in the one shipping (MAS) build:
toolbar/menu visible → init if needed → commit → repo created via REST → token prompt if needed →
`origin` set → pushed → link surfaced. No `gh` CLI dependency anywhere in this feature.

## Non-goals

- The non-Darwin (`GHRepoProvider`, subprocess `gh`/`git`) provider path is untouched — it belongs
  to the cross-platform port (#571), which has no GUI yet to wire it into.
- No generalization of `TokenOnboarding` into a shared `TokenOnboarding<Account>` for both Cloudflare
  and GitHub. The two verifiers already have slightly different shapes (Cloudflare's takes a
  `siteDirectory`; GitHub's doesn't), and unifying them would mean touching `DeployModel`, which
  CONTRIBUTING.md's "no drive-by refactors of unrelated code" argues against. `GitHubTokenOnboarding`
  is a small sibling type, not a refactor of the Cloudflare one.
- No changes to `RepoBootstrap`, `HTTPRepoProvider`, `HTTPGitHubClient`, or the SwiftGit2 preflight —
  that plumbing is correct and already tested (#663/#659/#779).

## Design

### A — Delete the dead gh-CLI auth path

All of the following are unreachable in every current build configuration (confirmed: `ANGLESITE_MAS`
is defined for both the Xcode app target and the SPM `AnglesiteAppCore` test target) and are being
replaced by the token-row flow in part C:

- `Sources/AnglesiteApp/GitHubAuthSheetView.swift` — deleted.
- `Sources/AnglesiteCore/GitHubAuthFlow.swift` and `Tests/AnglesiteCoreTests/GitHubAuthFlowTests.swift`
  — deleted.
- `GitHubAuthRow` (private struct in `SettingsView.swift`) and the private `ResolveBinary` enum it
  alone uses — deleted.
- `SettingsView.swift`'s Credentials section: collapse the `#if !ANGLESITE_MAS ... #else ... #endif`
  around the GitHub row down to just the `KeychainTokenRow` branch, unconditionally.

### B — Un-gate the working UI

Remove the `#if !ANGLESITE_MAS`/`#endif` wrapping (no logic changes) around:

- `SiteWindow.swift:412-434` — the toolbar item (`SiteToolbarItemID.github`).
- `SiteWindow.swift:531-534` — the `PublishSheet` `.sheet` modifier (the `GitHubAuthSheetView`
  `.sheet` next to it is replaced, not just un-gated — see part C).
- `WebsiteCommands.swift:81-95` — the Site ▸ GitHub menu.
- `PublishSheet.swift` — the whole-file `#if !ANGLESITE_MAS` wrapper.
- `SiteWindowModel.swift:464-466` — `canPublishToGitHub`.

### C — New `.needsAuth` flow

Mirrors `DeployModel`'s existing "deploy blocked on missing Cloudflare token" pattern
(`tokenPromptPresented` / `TokenVerification` / `pendingDeploy` / `verifyAndSaveToken` /
`cancelTokenPrompt`, and the `TokenOnboarding` core type it delegates ordering to), applied to
GitHub:

**`GitHubTokenOnboarding`** (new, `Sources/AnglesiteCore/GitHubTokenOnboarding.swift`, `@MainActor`
struct, mirrors `TokenOnboarding`):

```swift
@MainActor
public struct GitHubTokenOnboarding {
    public enum Outcome: Equatable {
        case proceed(GitHubAccount)
        case stay(message: String)
        case abort
    }
    public init(verifier: GitHubTokenVerifying)
    public func run(
        token: String,
        persist: (String) throws -> Void,
        onConnected: (GitHubAccount) -> Void,
        delay: () async -> Void,
        isCancelled: () -> Bool
    ) async -> Outcome
}
```

Same verify → persist-only-on-success → surface connected account → re-check-cancel → proceed
ordering as `TokenOnboarding`, minus the `siteDirectory` parameter (`GitHubTokenVerifying.verify`
takes only a token — no site-scoped check exists for GitHub, unlike Cloudflare's wrangler-based
verification).

**`PublishModel` changes** (`Sources/AnglesiteApp/PublishModel.swift`):

- Replace `authSheetPresented: Bool` with `tokenPromptPresented: Bool`.
- Add `tokenVerification: TokenVerification` (same four cases as `DeployModel`'s: `.idle`,
  `.checking`, `.connected(accountName:)`, `.failed(message:)`).
- Add a private parked-publish slot: `pendingPublish: (source: URL, repoName: String)?`.
- `consume(_:source:)`'s `.needsAuth` case: instead of `authSheetPresented = true`, park
  `pendingPublish = (source, repoName)` — note `repoName` isn't currently threaded into `consume`;
  it needs to be passed in from `start(source:repoName:)` alongside `source` — and set
  `tokenPromptPresented = true`, `tokenVerification = .idle`, `sheetPresented = false`.
- Replace `authCompleted(source:repoName:)` with:
  - `func verifyAndSaveToken(_ token: String) async` — delegates to
    `GitHubTokenOnboarding.run(...)` with `persist: { try KeychainStore().writeGitHubToken($0) }`
    and `onConnected: { AppSettings.shared.gitHubAccount = $0 }` (matching what the Settings row
    already does, so a token saved from either entry point shows "Signed in as …" in both places);
    on `.proceed` clears the prompt and re-invokes `start(source:repoName:)` with the parked values.
  - `func cancelTokenPrompt()` — clears `pendingPublish`, `tokenPromptPresented`, resets
    `tokenVerification`.
- `PublishModel.init` gains a `verifier: GitHubTokenVerifying = GitHubAPITokenVerifier()` parameter
  (mirroring `DeployModel`'s `verifier:` init param) so tests can inject a fake.

**`GitHubTokenPromptView`** (new, `Sources/AnglesiteApp/GitHubTokenPromptView.swift`, modeled
directly on `CloudflareTokenPromptView`):

- Header: "Connect to GitHub" / "Publishing needs a one-time personal access token."
- One numbered step (simpler than Cloudflare's three — no template pre-fill exists for GitHub
  fine-grained tokens): `Link` to `https://github.com/settings/tokens?type=beta` with the label
  "Open GitHub personal access tokens", plus a line of body text telling the user to create a
  fine-grained token with **Contents: read and write** access and paste it below (matching the
  existing Settings row's caption text).
- `SecureField` + status line (checking/connected/failed) + Cancel / "Connect & publish" buttons,
  structurally identical to `CloudflareTokenPromptView`.
- `submit()` calls `model.verifyAndSaveToken(token)`.

**`SiteWindow.swift`** wiring:

```swift
.sheet(isPresented: $bindableModel.publish.tokenPromptPresented) {
    GitHubTokenPromptView(model: model.publish) {
        model.publish.cancelTokenPrompt()
    }
}
```
replacing the current `GitHubAuthSheetView` `.sheet`.

**Doc comment cleanup:** `RepoBootstrap.swift:21`'s comment ("The UI presents `GitHubAuthSheetView`,
then retries `publish`") gets updated to describe the token-prompt flow instead.

### Data flow (happy path, no token yet)

1. User clicks "Publish to GitHub" (toolbar, menu, or a fresh `.anglesite` package).
2. `PublishModel.publish(source:repoName:)` → `start(...)` → `RepoBootstrap.publish(...)` stream.
3. `HTTPRepoProvider.isAuthenticated()` is false (no Keychain token yet) → `RepoBootstrap` emits
   `.needsAuth`.
4. `PublishModel.consume` parks `pendingPublish`, presents `GitHubTokenPromptView`.
5. User pastes a token, clicks "Connect & publish" → `verifyAndSaveToken` → `GitHubTokenOnboarding.run`
   → `GitHubAPITokenVerifier.verify` succeeds → token written to Keychain, `AppSettings.gitHubAccount`
   set, brief "Connected to <login>" flash → prompt dismissed.
6. `verifyAndSaveToken` re-invokes `start(source:repoName:)` with the parked values →
   `PublishSheet` reappears, `RepoBootstrap.publish` re-runs — this time `isAuthenticated()` is true
   — repo created via REST, `origin` added, pushed.
7. `.published(repo)` → `PublishSheet` shows the link; `existingRemote` updates so the toolbar/menu
   swap to "View on GitHub".

### Error handling

- Token verification failure (bad token, network error): `GitHubTokenOnboarding` returns `.stay`,
  `GitHubTokenPromptView` shows the message inline, prompt stays open, Keychain untouched — same
  behavior as the Cloudflare prompt.
- User cancels the token prompt: `cancelTokenPrompt()` clears the parked publish; the toolbar
  button returns to "Publish to GitHub" (not stuck mid-flight) since `isRunning` was never true
  during the `.needsAuth` park.
- Repo creation/push failures after a token exists (name collision, network, etc.) are unchanged —
  still surfaced via `.failed(reason:)` in `PublishSheet`, same as today.

### Testing

- New `Tests/AnglesiteCoreTests/GitHubTokenOnboardingTests.swift`, mirroring
  `TokenOnboardingTests.swift`: verify-then-persist ordering, persist-only-on-success, the
  cancel-during-delay race (`isCancelled` re-check), and the empty-token guard.
- No new app-level (`AnglesiteAppTests`) tests planned — `PublishModel`/`DeployModel` don't have
  existing hosted-app test coverage either; this follows the codebase's established pattern of
  keeping the testable ordering logic in `AnglesiteCore` and covering the SwiftUI layer via manual
  smoke (per CLAUDE.md's note on `xcodebuild test` not running on CI's older runners).
- Existing `RepoBootstrapTests`, `HTTPRepoProviderTests`, `GitHubTokenVerifierTests` are unaffected
  (no changes to the types they cover).
- Manual smoke (Xcode, real toolchain — required per CONTRIBUTING.md since this is UI work):
  toolbar/menu item now visible in a Debug build → click Publish with no token stored → prompt
  appears → paste an invalid token (see inline error, prompt stays open) → paste a valid token →
  see "Connected to <login>" flash → publish auto-continues → `PublishSheet` shows the published
  link → toolbar/menu swap to "View on GitHub" → clicking it opens the repo in the browser.

## Files touched

**Deleted:**
- `Sources/AnglesiteApp/GitHubAuthSheetView.swift`
- `Sources/AnglesiteCore/GitHubAuthFlow.swift`
- `Tests/AnglesiteCoreTests/GitHubAuthFlowTests.swift`

**Added:**
- `Sources/AnglesiteCore/GitHubTokenOnboarding.swift`
- `Sources/AnglesiteApp/GitHubTokenPromptView.swift`
- `Tests/AnglesiteCoreTests/GitHubTokenOnboardingTests.swift`

**Modified:**
- `Sources/AnglesiteApp/PublishModel.swift` — new state/methods per part C.
- `Sources/AnglesiteApp/SiteWindow.swift` — un-gate toolbar item + `PublishSheet` sheet; replace
  the auth sheet with `GitHubTokenPromptView`.
- `Sources/AnglesiteApp/WebsiteCommands.swift` — un-gate the GitHub menu.
- `Sources/AnglesiteApp/PublishSheet.swift` — remove file-level `#if !ANGLESITE_MAS`.
- `Sources/AnglesiteApp/SiteWindowModel.swift` — un-gate `canPublishToGitHub`.
- `Sources/AnglesiteApp/SettingsView.swift` — remove `GitHubAuthRow` + `ResolveBinary`; collapse
  the Credentials section's GitHub branch to unconditional `KeychainTokenRow`.
- `Sources/AnglesiteCore/RepoBootstrap.swift` — update the stale `.needsAuth` doc comment.

## Acceptance (from issue #654)

Publish to GitHub works end-to-end from a signed, sandboxed build with no `gh` installed: init if
needed → initial commit → repo created via REST → token prompt if needed → `origin` set → pushed.
