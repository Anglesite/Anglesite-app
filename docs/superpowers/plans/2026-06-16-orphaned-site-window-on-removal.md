# Auto-close an Orphaned SiteWindow on Site Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When an owner removes a site from the launcher while that site's window is open, the window auto-closes — stopping its dev-server/MCP subprocess and releasing any sandbox grant — instead of being left orphaned.

**Architecture:** Add an `AsyncStream<[Site]>` broadcast to the `SiteStore` actor (a dictionary of continuations fanned out from `emitChange()`, pruned via `onTermination`). Each `SiteWindow` consumes its own stream in a `.task` and calls `dismissWindow()` the first time a registry snapshot no longer contains its `siteID`. `dismissWindow()` triggers the existing `onDisappear` teardown, so subprocess shutdown and grant release come for free. The existing single `changeHandler` (Spotlight indexer) is left untouched.

**Tech Stack:** Swift 6.4 / Swift Testing (`@Test`) for `AnglesiteCore`; SwiftUI for the app target. Build verification via `swift test` (core) and `xcodebuild` (app target, both schemes).

**Spec:** [`docs/superpowers/specs/2026-06-16-orphaned-site-window-on-removal-design.md`](../specs/2026-06-16-orphaned-site-window-on-removal-design.md)

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `Sources/AnglesiteCore/SiteStore.swift` | Registry actor; gains a UI-observer broadcast alongside the indexer handler | Modify |
| `Tests/AnglesiteCoreTests/SiteStoreTests.swift` | Unit tests for the broadcast mechanics | Modify |
| `Sources/AnglesiteApp/SiteWindow.swift` | Per-site window; observes the broadcast and auto-closes | Modify |
| `Sources/AnglesiteApp/SitesLauncherView.swift` | Launcher; its `removeSite` doc-comment currently records the gap being fixed | Modify (comment only) |

---

## Task 1: `SiteStore` broadcast stream

**Files:**
- Modify: `Sources/AnglesiteCore/SiteStore.swift` (add property near `changeHandler` at line 65; add `changeStream()` + `removeContinuation(_:)` in the "Change notification" section ~line 220; restructure `emitChange()` at lines 222-225)
- Test: `Tests/AnglesiteCoreTests/SiteStoreTests.swift` (new tests after the existing "Change handler" section, ~line 296)

- [ ] **Step 1: Write the failing tests**

Add these four tests to `SiteStoreTests.swift`, immediately after the `changeHandlerCanBeCleared` test (after line 296, before the `// MARK: - Sandbox bookmark retention (#184)` mark):

```swift
    // MARK: - Change stream broadcast (#188)

    @Test("Change stream yields the current snapshot on subscribe")
    func changeStreamYieldsCurrentSnapshotOnSubscribe() async throws {
        _ = try makeValidSite(named: "alpha")
        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        try await store.refresh()

        var iterator = store.changeStream().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.map(\.name) == ["alpha"])
    }

    @Test("Change stream delivers a post-remove snapshot without the removed id")
    func changeStreamDeliversRemoval() async throws {
        _ = try makeValidSite(named: "alpha")
        _ = try makeValidSite(named: "bravo")
        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        try await store.refresh()
        let alphaID = try #require(await store.sites.first { $0.name == "alpha" }).id

        var iterator = store.changeStream().makeAsyncIterator()
        _ = await iterator.next() // drain the subscribe-time snapshot ([alpha, bravo])

        try await store.remove(id: alphaID)

        let afterRemove = await iterator.next()
        #expect(afterRemove?.contains { $0.id == alphaID } == false)
        #expect(afterRemove?.map(\.name) == ["bravo"])
    }

    @Test("Change stream fans out to multiple subscribers")
    func changeStreamFansOutToMultipleSubscribers() async throws {
        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        var iterA = store.changeStream().makeAsyncIterator()
        var iterB = store.changeStream().makeAsyncIterator()
        _ = await iterA.next() // subscribe-time snapshot ([] on a fresh store)
        _ = await iterB.next()

        let dir = try makeValidSite(named: "alpha")
        _ = try await store.add(dir)

        let a = await iterA.next()
        let b = await iterB.next()
        #expect(a?.map(\.name) == ["alpha"])
        #expect(b?.map(\.name) == ["alpha"])
    }

    @Test("A cancelled subscriber does not break a surviving one")
    func changeStreamSurvivesSubscriberCancellation() async throws {
        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)

        // Subscriber 1 iterates in a task we'll cancel — its stream then terminates and its
        // continuation is pruned via onTermination.
        let task1 = Task {
            for await _ in store.changeStream() { /* drain until cancelled */ }
        }
        // Subscriber 2 persists for the whole test.
        var iter2 = store.changeStream().makeAsyncIterator()
        _ = await iter2.next() // subscribe-time snapshot ([])

        task1.cancel()
        _ = await task1.value // let cancellation + onTermination settle

        let dir = try makeValidSite(named: "alpha")
        _ = try await store.add(dir)

        let survivor = await iter2.next()
        #expect(survivor?.map(\.name) == ["alpha"], "emitChange must still deliver after another subscriber is gone")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter SiteStoreTests/changeStream 2>&1 | tail -20`
Expected: compile failure — `value of type 'SiteStore' has no member 'changeStream'`.

- [ ] **Step 3: Add the continuation storage property**

In `Sources/AnglesiteCore/SiteStore.swift`, directly after the `private var changeHandler: ChangeHandler?` declaration (line 65), add:

```swift

    /// Continuations for the UI-observer broadcast, keyed by a per-subscription `UUID`. Distinct
    /// from `changeHandler`: that single closure is the indexer's awaited post-mutation hook, while
    /// these are fire-and-forget snapshot feeds that SwiftUI windows consume to notice their site
    /// being removed (#188). Pruned in `removeContinuation(_:)` via the stream's `onTermination`.
    private var changeStreamContinuations: [UUID: AsyncStream<[Site]>.Continuation] = [:]
```

- [ ] **Step 4: Add `changeStream()` and `removeContinuation(_:)`**

In the `// MARK: - Change notification` section of `SiteStore.swift`, directly above the existing `private func emitChange()` (line 222), add:

```swift
    /// Vends a per-subscriber broadcast of the site list. Every call registers a fresh
    /// continuation; the stream yields the current `sites` snapshot once on subscribe (so a
    /// subscriber isn't blind until the next mutation, and a removal that races subscription is
    /// caught immediately), then a new snapshot after every `emitChange()`. The continuation is
    /// pruned when the stream terminates (consumer task cancelled, iterator dropped, or store gone).
    public func changeStream() -> AsyncStream<[Site]> {
        let id = UUID()
        return AsyncStream { continuation in
            // This builder runs synchronously on the actor, so touching actor state is safe here.
            changeStreamContinuations[id] = continuation
            continuation.yield(sites)
            continuation.onTermination = { [weak self] _ in
                // onTermination runs off-actor at an arbitrary time; hop back to prune.
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        changeStreamContinuations[id] = nil
    }
```

- [ ] **Step 5: Restructure `emitChange()` to also fan out to the broadcast**

Replace the existing `emitChange()` (lines 222-225):

```swift
    private func emitChange() async {
        guard let handler = changeHandler else { return }
        await handler(sites)
    }
```

with:

```swift
    private func emitChange() async {
        // The indexer's awaited hook keeps its original semantics: when set, it completes as part
        // of the mutation. The broadcast is additive — UI observers get a fire-and-forget snapshot
        // even when no `changeHandler` is installed.
        if let handler = changeHandler {
            await handler(sites)
        }
        for continuation in changeStreamContinuations.values {
            continuation.yield(sites)
        }
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path . --filter SiteStoreTests/changeStream 2>&1 | tail -20`
Expected: 4 tests pass.

- [ ] **Step 7: Run the full `SiteStoreTests` suite to confirm no regression**

Run: `swift test --package-path . --filter SiteStoreTests 2>&1 | tail -20`
Expected: all `SiteStoreTests` pass — in particular the existing `changeHandler*` tests (the indexer path is unchanged) and `changeHandlerDoesNotFireOnNoFileLoad` (the `load()` early-return still precedes `emitChange`).

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteCore/SiteStore.swift Tests/AnglesiteCoreTests/SiteStoreTests.swift
git commit -m "feat(core): broadcast SiteStore changes via AsyncStream (#188)

Add changeStream() — a per-subscriber AsyncStream<[Site]> fanned out from
emitChange(), yielding the current snapshot on subscribe and pruning its
continuation onTermination. The existing single changeHandler (Spotlight
indexer) is untouched. Lets a SiteWindow observe its site being removed.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `SiteWindow` observes removal and auto-closes

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift` (add a `.task` modifier in `body` after the existing `.task(id: siteID)` at line 67; add an `observeRemoval()` method in the `// MARK: - Lifecycle` section)
- Modify: `Sources/AnglesiteApp/SitesLauncherView.swift` (update the now-stale gap comment in `removeSite`, lines 230-233)

> No unit test: SwiftUI window dismissal isn't exercisable in `swift test`. The decision logic is a one-line membership check; correctness rests on Task 1's store tests plus the manual smoke in Task 3. This task is verified by building both schemes.

- [ ] **Step 1: Add the observation `.task` to `SiteWindow.body`**

In `Sources/AnglesiteApp/SiteWindow.swift`, the `body` currently ends the `Group` with:

```swift
        .task(id: siteID) { await loadAndStart() }
        .onDisappear {
```

Insert a second `.task` between them so it reads:

```swift
        .task(id: siteID) { await loadAndStart() }
        .task(id: site?.id) { await observeRemoval() }
        .onDisappear {
```

Keying on `site?.id` (the *resolved* site, not the raw `siteID`) means observation only starts once `loadAndStart` has populated `site` from the store — avoiding a cold-launch race where an empty pre-load snapshot would otherwise look like "my site is gone".

- [ ] **Step 2: Add the `observeRemoval()` method**

In `SiteWindow.swift`, in the `// MARK: - Lifecycle` section, directly above `private func loadAndStart() async {` (line 274), add:

```swift
    /// Auto-close this window when its site leaves the registry (#188). Subscribes to the store's
    /// broadcast only after `site` is resolved; on the first snapshot that no longer contains this
    /// site's id — an explicit `remove(id:)` from the launcher, or a `refresh()` that prunes a stale
    /// entry — dismisses the window. `dismissWindow()` triggers `onDisappear`, which stops the
    /// dev-server/MCP subprocess and releases the MAS security-scoped grant, so no teardown is
    /// duplicated here. The `for await` loop is cancelled when the window tears down or `site`
    /// changes, which terminates the stream and prunes the store-side continuation.
    private func observeRemoval() async {
        guard let resolvedID = site?.id else { return }
        for await snapshot in SiteStore.shared.changeStream() {
            if !snapshot.contains(where: { $0.id == resolvedID }) {
                dismissWindow()
                return
            }
        }
    }
```

- [ ] **Step 3: Update the stale gap comment in the launcher**

In `Sources/AnglesiteApp/SitesLauncherView.swift`, replace the `removeSite` doc-comment paragraph that records the known gap (lines 230-233):

```swift
    /// Note: an already-open `SiteWindow` for this site is *not* signalled — `SiteStore`'s change
    /// handler is single-subscriber (the Spotlight indexer), so the window keeps running its
    /// dev-server/MCP subprocess against a now-orphaned entry until the user closes it. Closing or
    /// warning the open window is left as a follow-up.
```

with:

```swift
    /// An already-open `SiteWindow` for this site auto-closes: it observes `SiteStore.changeStream()`
    /// and dismisses itself when its id leaves the registry, which tears down its dev-server/MCP
    /// subprocess via `onDisappear` (#188).
```

- [ ] **Step 4: Build the DevID scheme**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Build the MAS scheme**

The new `.task` and `observeRemoval()` are unguarded (no `#if`), so they must compile in the sandboxed target too.

Run: `xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindow.swift Sources/AnglesiteApp/SitesLauncherView.swift
git commit -m "feat(app): auto-close a SiteWindow when its site is removed (#188)

SiteWindow now observes SiteStore.changeStream() and dismisses itself the
first time a registry snapshot lacks its resolved id; onDisappear then
stops the dev-server/MCP subprocess and releases the MAS grant. Update the
launcher's removeSite comment, which documented the now-closed gap.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Manual smoke + issue closeout

**Files:** none (verification + bookkeeping)

- [ ] **Step 1: Single-window auto-close smoke**

Launch the app (DevID scheme from Xcode, or the built `.app`). Open a site window. With the launcher still open, remove that site (context-menu or swipe → confirm). Observe:
- The site's window closes.
- In the Debug pane, the site's dev-server/MCP subprocess streams its shutdown and stops (no orphaned child).

If a `~/Sites` throwaway is needed, use `~/Sites/smoke` (disposable test state).

- [ ] **Step 2: Two-window isolation smoke**

Open two site windows. Remove one site from the launcher. Observe: only the removed site's window closes; the other window keeps running its preview unaffected.

- [ ] **Step 3: (MAS, if a signed/sandboxed build is available) grant-release smoke**

In a sandboxed build, repeat Step 1 and confirm the window closes cleanly with no security-scoped-access errors logged — `onDisappear`'s `scopedURL?.stopAccessingSecurityScopedResource()` runs as part of the dismissal. If no signed MAS build is available, note this as deferred (consistent with the deferred Phase 10.1 real-signed smoke).

- [ ] **Step 4: Close out the issue**

```bash
gh issue comment 188 --body "Fixed: SiteWindow now observes SiteStore.changeStream() and auto-closes when its site leaves the registry, tearing down the dev-server/MCP subprocess via onDisappear. Store broadcast unit-tested in SiteStoreTests; window auto-close + subprocess stop verified by manual smoke."
```

Leave the issue open until the PR that carries these commits merges (the PR's "Closes #188" handles the final close).

---

## Self-Review

**Spec coverage:**
- "Auto-close the window" UX → Task 2 (`observeRemoval` + `dismissWindow()`). ✓
- AsyncStream broadcast on `SiteStore`, `changeHandler` untouched → Task 1 (Steps 3-5; existing handler preserved, verified by Step 7). ✓
- Subscribe-time snapshot → Task 1 Step 4 (`continuation.yield(sites)`); tested in `changeStreamYieldsCurrentSnapshotOnSubscribe`. ✓
- `onTermination` prune → Task 1 Step 4 (`removeContinuation`); exercised by `changeStreamSurvivesSubscriberCancellation`. ✓
- Edge: nil `siteID` never subscribes → Task 2 keys on `site?.id` and guards `guard let resolvedID = site?.id`. ✓
- Edge: `refresh()`-prune auto-closes → membership check in `observeRemoval` is mutation-agnostic. ✓
- Acceptance "no orphaned subprocess" → `dismissWindow()` → `onDisappear` → `preview.close()`; verified in Task 3 Steps 1-2. ✓
- Testing plan (store mechanics unit-tested, window glue via manual smoke) → Tasks 1 and 3. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code and every command shows expected output. ✓

**Type consistency:** `changeStream() -> AsyncStream<[Site]>`, `changeStreamContinuations: [UUID: AsyncStream<[Site]>.Continuation]`, `removeContinuation(_ id: UUID)`, and `observeRemoval()`'s `resolvedID`/`$0.id` usage are consistent across Tasks 1 and 2. `Site` is `SiteStore.Site` (the nested type used throughout the existing store + tests). ✓
