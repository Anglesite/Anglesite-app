# `AnglesiteCore` bounded-context target split - design

**Issue:** #437 - Plan AnglesiteCore target split around bounded contexts
**Date:** 2026-06-30
**Status:** Proposed design; ready for phased implementation planning.

## Goal

Split the current mixed-domain `AnglesiteCore` SwiftPM target into smaller package targets around stable bounded contexts, without forcing a large app/intents import rewrite in the first PR.

The split should improve compile times, ownership, and API boundaries while preserving the current product surface during migration:

- `AnglesiteApp`, `AnglesiteBridge`, and `AnglesiteIntents` can continue importing `AnglesiteCore` initially.
- New targets expose narrower public APIs as files move.
- `AnglesiteCore` becomes a compatibility/facade target during the migration, then shrinks to orchestration glue or disappears once callers import the bounded targets directly.

## Current shape

`Package.swift` currently exposes:

- `AnglesiteCore`, the shared dependency root.
- `AnglesiteBridge`, depending on `AnglesiteCore`.
- `AnglesiteIntents`, depending on `AnglesiteCore`.
- `AnglesiteTestSupport`, depending on `AnglesiteCore`.
- Test targets mostly grouped under `AnglesiteCoreTests`.

`AnglesiteCore` holds several domains that are now independently recognizable:

- Package and site identity: `AnglesitePackage`, `SiteStore`, `RecentSites`, `SiteConfigStore`, `SecurityScopedBookmark`, `UTType+Anglesite`, `ProjectValidator`, `SiteAccess`.
- Runtime/process supervision: `SiteRuntime`, `LocalSiteRuntime`, `RemoteSandboxSiteRuntime`, `HeadlessRuntimePool`, `ProcessSupervisor`, `AstroDevServer`, `NodeRuntime`, `PluginRuntime`, `TemplateRuntime`, transports, MCP clients.
- Content model and operations: `SiteContentGraph`, `ContentScanner`, `Frontmatter`, `ContentListing`, `NavigatorTree`, `NativeContentOperations`, `ContentOperations`, editor/router types.
- Assistant/chat/RAG: `ConversationTranscript`, `ConversationalAssistant`, `ClaudeAssistant`, `FoundationModelAssistant`, edit interpretation, tools, chat history, token onboarding.
- Deployment/security/integrations: `DeployCommand`, `BackupCommand`, `AuditCommand`, `PreDeployCheck`, `A11yAuditRunner`, `CloudflareTokenVerifier`, deploy summaries, integration catalog/planning/scaffolding.
- Shared support: `LogCenter`, `OperationProgress`, `BuildInfo`, `KeychainStore`, `AppSettings`, startup timing/progress, file document helpers.

The major implementation constraint is that these domains are not cleanly independent yet. For example, `LocalSiteRuntime` owns a `SiteContentGraph` and uses `ContentScanner`; `ContentOperations` depends on `HeadlessRuntimePool` and `MCPClient`; deploy/token verification depend on `ProcessSupervisor`, `NodeRuntime`, and `LogCenter`.

## Target map

### `AnglesiteFoundation`

Small shared primitives with no dependency on site/package, runtime, content, assistant, or deployment domains.

Candidate files:

- `BuildInfo.swift`
- `OperationProgress.swift`
- `LogCenter.swift`
- `StartupTiming.swift`
- `StartupProgressEstimator.swift`
- `FileDocumentIO.swift`
- `KeychainStore.swift`
- `AppSettings.swift`
- `LiveRegionAnnouncer.swift`

Boundary rule: this target must stay boring. If a type knows about package layout, MCP, content, Cloudflare, assistant providers, or app-specific workflows, it does not belong here.

### `AnglesiteSiteModel`

Site identity, package layout, recents, config, validation, bookmarks, and file access.

Candidate files:

- `AnglesitePackage.swift`
- `SiteStore.swift`
- `RecentSites.swift`
- `SiteConfigFile.swift`
- `SiteConfigStore.swift`
- `SiteAccess.swift`
- `SecurityScopedBookmark.swift`
- `ProjectValidator.swift`
- `UTType+Anglesite.swift`
- `PackageTransfer.swift`
- `BundleSync.swift`
- `NewSiteDraft.swift`
- `RepoBootstrapTypes.swift`

Expected dependencies:

- Depends on `AnglesiteFoundation`.
- Must not depend on runtime, content, assistant, deployment, or app/intents targets.

This is the best first extraction because most files are value types, persistence helpers, or filesystem validators. The few callers outside the domain already treat these types as package/site identity APIs.

### `AnglesiteRuntime`

Process execution, Node/plugin runtime, MCP transports/clients, live preview runtimes, and headless runtime pooling.

Candidate files:

- `ProcessSupervisor.swift`
- `SupervisorBackend.swift`
- `InProcessBackend.swift`
- `SiteRuntime.swift`
- `LocalSiteRuntime.swift`
- `RemoteSandboxSiteRuntime.swift`
- `HeadlessRuntimePool.swift`
- `AstroDevServer.swift`
- `NodeRuntime.swift`
- `NodeModulesCache.swift`
- `PluginRuntime.swift`
- `TemplateRuntime.swift`
- `MCPClient.swift`
- `MCPTransport.swift`
- `HTTPTransport.swift`
- `StdioTransport.swift`
- `TextStreamRelay.swift`
- `TurnRelay.swift`
- `SandboxControlClient.swift`
- `HTTPSandboxControlClient.swift`
- `SessionToken.swift`
- `XPC/SpawnTypes.swift`

Expected dependencies:

- Depends on `AnglesiteFoundation`.
- Depends on `AnglesiteSiteModel` only for package/source URL helpers if runtime callers move from raw `siteDirectory` URLs to `AnglesitePackage`.
- Should not depend on `AnglesiteContent` in the final shape.

Current cycle risk: `LocalSiteRuntime` populates `SiteContentGraph` through `ContentScanner`. Break this by introducing a runtime observer or callback:

- Runtime reports "site became ready at directory".
- An app/core orchestration layer scans content and loads the graph.
- `LocalSiteRuntime` no longer imports content types.

### `AnglesiteContent`

Content graph, scanning, frontmatter, navigator tree, content scaffolding/operations, and editor-domain routing.

Candidate files:

- `SiteContentGraph.swift`
- `ContentScanner.swift`
- `ContentListing.swift`
- `Frontmatter.swift`
- `GenerableTypes.swift`
- `ContentScaffold.swift`
- `NativeContentOperations.swift`
- `ContentOperationsService.swift`
- `ContentOperations.swift`
- `NavigatorTree.swift`
- `NavigatorRenameService.swift`
- `SiteFileTree.swift`
- `PageTitleEditor.swift`
- `HomepageWriter.swift`
- `ThemeCatalog.swift`
- `ThemeApplier.swift`
- `LogoAsset.swift`
- `HeroImage.swift`
- `EditorKind.swift`
- `EditMessage.swift`
- `InterpretedEdit.swift`
- `EditRouter.swift`
- `EditRouterRegistry.swift`
- `MCPApplyEditRouter.swift`
- `ApplyEditTool.swift`
- `SearchContentTool.swift`
- `UndoCommand.swift`
- `MarkerInjector.swift`
- `AnnotationStore.swift`
- `AnnotationFeed.swift`
- `PreviewNavigation.swift`
- `VisibleElementMessage.swift`

Expected dependencies:

- Depends on `AnglesiteFoundation`.
- Depends on `AnglesiteSiteModel` for package/source URLs.
- May depend on `AnglesiteRuntime` only through narrow protocols for MCP tool calls during the transition.

The final direction should prefer native filesystem content operations where practical. Anything that must call MCP should depend on a small protocol, not the full runtime target, so content can be tested without spawning the plugin runtime.

### `AnglesiteAssistant`

Provider-agnostic assistant contracts, transcript reduction, chat history, provider adapters, edit interpretation, assistant tools, and semantic ranking/knowledge index.

Candidate files:

- `ConversationTranscript.swift`
- `ConversationalAssistant.swift`
- `ClaudeAssistant.swift`
- `ClaudeAgent.swift`
- `FoundationModelAssistant.swift`
- `FoundationModelEditInterpreter.swift`
- `FoundationModelDeploySummarizer.swift`
- `ContentAssistant.swift`
- `AltTextGenerator.swift`
- `ChatHistoryStore.swift`
- `TokenOnboarding.swift`
- `IntentEditBridge.swift`
- `IntentEditBridgeOverride.swift`

Expected dependencies:

- Depends on `AnglesiteFoundation`.
- Depends on `AnglesiteContent` for edit/content tool contracts.
- Depends on `AnglesiteSiteModel` for per-site chat history location.
- Should not depend on deployment directly; deploy summarization should consume a small log-summary input type or live in deployment if it is deploy-specific.

### `AnglesiteDeployment`

Deploy, backup, audit, harden/security checks, Cloudflare/token verification, integrations, health/readiness, and repository bootstrap workflows.

Candidate files:

- `DeployCommand.swift`
- `BackupCommand.swift`
- `AuditCommand.swift`
- `DeployFailureSummary.swift`
- `DeployFailureSummaryRequest.swift`
- `DeployLogDigest.swift`
- `PreDeployCheck.swift`
- `A11yAuditRunner.swift`
- `AuditReport.swift`
- `CloudflareTokenVerifier.swift`
- `GitHubAuthFlow.swift`
- `RepoBootstrap.swift`
- `RepoBootstrapTypes.swift` if not kept in site model
- `HealthModel.swift`
- `DefaultHealthCheckRunner.swift`
- `SiriReadiness.swift`
- `SiriReadinessSiteProbes.swift`
- `SiriReadinessSystemProbes.swift`
- `IntegrationDescriptor.swift`
- `IntegrationCatalog.swift`
- `IntegrationPlan.swift`
- `IntegrationPlanner.swift`
- `IntegrationScaffolder.swift`
- `IntegrationOperationsService.swift`
- `IntegrationOperations.swift`
- `IntegrationWizardModel.swift`
- `SetupIntegrationTool.swift`
- `CommandFactory.swift`

Expected dependencies:

- Depends on `AnglesiteFoundation`.
- Depends on `AnglesiteSiteModel` for source/package resolution.
- Depends on `AnglesiteRuntime` for supervised subprocess execution and Node/Wrangler resolution.
- May depend on `AnglesiteContent` for generated content/integration file edits.

## Dependency direction

The intended acyclic graph is:

```text
AnglesiteFoundation
  <- AnglesiteSiteModel
  <- AnglesiteRuntime
  <- AnglesiteContent
  <- AnglesiteAssistant
  <- AnglesiteDeployment
```

More precisely:

```text
AnglesiteSiteModel   -> AnglesiteFoundation
AnglesiteRuntime     -> AnglesiteFoundation, AnglesiteSiteModel
AnglesiteContent     -> AnglesiteFoundation, AnglesiteSiteModel
AnglesiteAssistant   -> AnglesiteFoundation, AnglesiteSiteModel, AnglesiteContent
AnglesiteDeployment  -> AnglesiteFoundation, AnglesiteSiteModel, AnglesiteRuntime, AnglesiteContent
AnglesiteCore        -> all bounded targets during migration
AnglesiteBridge      -> AnglesiteCore initially, later AnglesiteRuntime/AnglesiteContent as needed
AnglesiteIntents     -> AnglesiteCore initially, later AnglesiteSiteModel/AnglesiteContent/AnglesiteDeployment as needed
AnglesiteApp         -> AnglesiteCore initially, later direct bounded targets
```

Forbidden directions:

- `AnglesiteFoundation` imports any Anglesite domain target.
- `AnglesiteSiteModel` imports runtime/content/assistant/deployment.
- `AnglesiteRuntime` imports assistant or deployment.
- `AnglesiteRuntime` imports content after the cycle-breaking callback lands.
- `AnglesiteContent` imports assistant or deployment.
- `AnglesiteAssistant` imports deployment.

## Migration strategy

Use `AnglesiteCore` as a temporary facade:

1. Add a bounded target and move a small file cluster into it.
2. Add the new target as a dependency of `AnglesiteCore`.
3. Keep app/intents/bridge imports unchanged while tests are moved or duplicated by target.
4. Narrow public APIs as files move: prefer `internal` inside the new target, and expose only what app/intents/bridge actually need.
5. Once a bounded target is stable, update selected downstream callers to import it directly.
6. Repeat until `AnglesiteCore` contains only cross-context composition or can be retired.

SwiftPM does not re-export dependencies by default. During the facade phase, either:

- Keep facade wrapper/typealias files in `Sources/AnglesiteCore` for moved public types that many callers still use, or
- Update imports in app/intents/bridge at the same time as the move for that cluster.

For this codebase, prefer import updates over many typealias shims once a moved cluster has fewer than roughly ten direct downstream call sites. Use shims only to keep the first low-risk extraction small.

## Recommended phasing

### Phase 0 - Dependency audit

Before moving files, generate and commit a lightweight dependency inventory:

- File-to-file references inside `Sources/AnglesiteCore`.
- Public types consumed by `Sources/AnglesiteApp`, `Sources/AnglesiteBridge`, and `Sources/AnglesiteIntents`.
- Tests that import each candidate target.

This can be a throwaway script or a checked-in note under the implementation plan. The point is to catch cycles before the first move.

### Phase 1 - Extract `AnglesiteSiteModel`

Move the package/site identity cluster first:

- `AnglesitePackage`
- site config/store/recents types that do not call runtime/deploy/content services
- `ProjectValidator`
- `SecurityScopedBookmark`
- package UTI helpers

Expected package changes:

- Add `AnglesiteFoundation` if needed for shared primitives.
- Add `AnglesiteSiteModel`.
- Make `AnglesiteCore` depend on `AnglesiteSiteModel`.
- Move corresponding tests from `AnglesiteCoreTests` into `AnglesiteSiteModelTests`, or add a new test target while leaving unrelated tests untouched.

This is the first implementation PR recommended by #437 because it has the lowest coupling and immediately validates the migration mechanics.

### Phase 2 - Extract process/runtime infrastructure

Move `ProcessSupervisor`, `LogCenter` if not already in foundation, Node/plugin runtime, MCP transports, and live preview runtime types.

Before moving `LocalSiteRuntime`, remove its direct ownership of content scanning/graph loading:

- Add a ready callback or event stream carrying `siteID` and source directory.
- Let a higher-level coordinator populate `SiteContentGraph`.
- Keep `SiteRuntime` focused on process/session lifecycle.

### Phase 3 - Extract content model and operations

Move graph/scanner/frontmatter/navigator/native operations and editor routing.

At this point, decide whether `ContentOperations` still needs MCP:

- If yes, depend on a small `ContentToolCalling` protocol supplied by runtime/core composition.
- If no, keep content fully filesystem-native and avoid runtime dependency.

### Phase 4 - Extract deployment/integrations/security

Move deploy, backup, audit, preflight, Cloudflare token verification, repo bootstrap, readiness, and integrations.

This phase should depend on runtime for supervised command execution and site model for package/source resolution. Do not let deployment types become the place where app UI state leaks back into shared targets.

### Phase 5 - Extract assistant/chat

Move transcript reducers and provider adapters after content and runtime boundaries are stable.

Assistant code currently crosses many workflows: edit routing, deploy summarization, chat history, provider-specific tools, and token onboarding. Splitting it later avoids baking temporary cycles into the package graph.

### Phase 6 - Shrink or remove `AnglesiteCore`

Update app/intents/bridge to import bounded targets directly. Leave `AnglesiteCore` only if it provides real composition value, such as factories that wire site store, runtime pool, content graph, assistant, and deployment services together.

## First implementation PR

The first PR should split out `AnglesiteSiteModel`.

Scope:

- Add new SwiftPM target `AnglesiteSiteModel`.
- Move the smallest coherent site/package identity file set.
- Add `AnglesiteSiteModelTests`.
- Keep `AnglesiteCore` as the dependency root for app/intents/bridge.
- Run focused moved tests plus full `swift test` if local toolchain permits.

API narrowing:

- Keep `AnglesitePackage` public.
- Keep persistence models public only when app/intents/bridge construct or inspect them.
- Make helper parsing, canonicalization, and migration internals `internal` once they live in the new target.
- Do not move runtime-dependent site operations in the first PR.

Definition of done:

- `Package.swift` has an acyclic dependency graph.
- Site/package tests pass from their new test target.
- `AnglesiteCoreTests` no longer owns tests for files moved to `AnglesiteSiteModel`.
- App, bridge, and intents still build without a broad import rewrite.

## Testing plan

For each extraction PR:

- Run the moved target's focused tests first.
- Run impacted downstream tests next (`AnglesiteCoreTests`, then bridge/intents tests if imports changed).
- Run `swift test --package-path .` before merging when the local Xcode beta toolchain is available.
- Keep test fixtures in the target whose public API they validate. Shared test-only helpers should remain in `AnglesiteTestSupport` only when multiple test targets need them.

## Risks and mitigations

- **SwiftPM re-export surprise:** moving a public type to a dependency target does not automatically make it available to callers importing `AnglesiteCore`. Mitigate with explicit import updates or short-lived facade shims.
- **Runtime/content cycle:** `LocalSiteRuntime` currently scans content into `SiteContentGraph`. Mitigate before extracting runtime by moving content population to orchestration.
- **Over-public APIs:** moving files can tempt making every dependency `public`. Mitigate by moving narrow clusters and reviewing access levels in each PR.
- **Test churn:** one large `AnglesiteCoreTests` target makes moves noisy. Mitigate by creating bounded test targets alongside bounded source targets.
- **XcodeGen/product sync:** the app links SwiftPM products through `project.yml`. Add products only when app targets import them directly; otherwise `AnglesiteCore` can depend on bounded targets internally during migration.
