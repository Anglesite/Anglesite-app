# Bucket 3 — Integration Wizard Framework (Design)

**Date:** 2026-06-20
**Status:** Design / approved — no implementation yet
**Relates to:** `docs/superpowers/specs/2026-06-20-claude-code-removal-roadmap-design.md` (Slice 3, Bucket 3); the `.anglesite` package model (#242).

## 1. Goal

Replace the prose "integration" skills (contact, newsletter, booking, donations,
giscus, …) with a single deterministic Swift framework. Each integration setup becomes
**one capability** exposed through **three front-doors** — a GUI wizard (the
non-technical default), a per-integration App Intent (Siri), and a Foundation Models
chat tool — all driving the **same** deterministic engine. No LLM is required to *run*
an integration; generative text is out of scope for these three.

This is the proving ground for the Bucket 3 pattern. It is proven here on three
integrations and templated across the rest later.

## 2. Locked decisions

Settled during brainstorming (2026-06-20):

| Decision | Choice |
|---|---|
| **Engine location** | **Pure Swift scaffolder** in `AnglesiteCore`. No new sidecar tool. CSP *generation* stays in the site's build-time `template/scripts/csp.ts`; the wizard only writes provider domains into `.site-config`. |
| **Proof integration set** | **Stateless trio: booking + donations + giscus** (component + `.site-config` + provider URL; no Cloudflare Worker, no secrets). |
| **Manifest form** | **Typed Swift structs** (`IntegrationDescriptor`) in `AnglesiteCore` — compile-checked, unit-testable, read by all three front-doors. |
| **Component placement into existing layouts** | **Marker-anchor string insertion** — template layouts ship named anchor comments; the scaffolder does idempotent delimited string insertion. No HTML/AST patcher. |
| **Front-door split** | Per-integration App Intents (typed Siri params); one shared `SetupIntegrationTool` for FM chat; one generic `IntegrationWizard` GUI rendering fields from the descriptor. |

## 3. Architecture

One capability, three front-doors, over a shared deterministic engine — all in Swift.

```
            ┌─ AddBookingIntent / AddDonationsIntent / AddGiscusIntent  (Siri, typed params)
 Integration├─ SetupIntegrationTool   (FM chat: integrationType + structured args)
 capability ├─ IntegrationWizard      (GUI: renders fields generically from the descriptor)
            └──────────────── all call ────────────────┐
                                                        ▼
        IntegrationDescriptor (typed struct)  →  IntegrationScaffolder (engine)
                                                        │
                              ┌─────────────────────────┼───────────────────────┐
                              ▼                          ▼                        ▼
                    copy template files        write .site-config keys    marker-anchor insertion
                    into Source/               (incl. CSP domains)        into existing layouts
```

### Module placement

- **`AnglesiteCore`** — `IntegrationDescriptor` + the three descriptors, `IntegrationScaffolder`
  (the `plan`/`apply` engine), the `IntegrationOperationsService` protocol,
  `SetupIntegrationTool`, **and the GUI `IntegrationWizardModel` (`@Observable`)**. The
  engine and the wizard model are pure value-in/value-out, so they are unit-testable on
  CI without a hosted app (matching the project's hosted-app CI limitation). This places
  `IntegrationWizardModel` in `AnglesiteCore` exactly as `NewSiteWizardModel` already lives
  there — only the SwiftUI view sits in the app target.
- **`AnglesiteApp`** — the `IntegrationWizard` SwiftUI view only (binds to the
  `AnglesiteCore` model), following `NewSiteWizard`.
- **`AnglesiteIntents`** — the per-integration App Intents, following `SiteIntents`
  conventions (`@Parameter`, `@Dependency`, `*Override.scoped` TaskLocal for tests).

## 4. The descriptor model

Each integration is a static `IntegrationDescriptor` value — **declarative data, not
imperative code**. Operations are gated by simple conditions and use `{{token}}`
substitution, so one engine drives all integrations and each descriptor stays testable.

```swift
public struct IntegrationDescriptor: Sendable {
    public let id: IntegrationID           // .booking, .donations, .giscus
    public let displayName: String
    public let summary: String
    public let providers: [Provider]       // empty when provider-less
    public let fields: [Field]
    public let operations: [Operation]     // declarative, each optionally gated
}

public struct Provider: Sendable, Identifiable {
    public let id: String                  // "cal", "calendly"
    public let displayName: String
    public let cspDomains: [String]        // contributed when this provider is chosen
}

public struct Field: Sendable, Identifiable {
    public let key: String                 // "username", "style"
    public let label: String
    public let kind: FieldKind             // .text / .email / .url / .choice([Choice]) / .bool
    public let isOptional: Bool
    public let defaultValue: String?
    public let help: String?
    public let visibleWhen: Condition      // .always | .providerIs("cal") | .fieldEquals(key,value)
}

public struct Choice: Sendable { public let value: String; public let label: String }

public enum FieldKind: Sendable {
    case text, email, url
    case choice([Choice])
    case bool
}

public enum Condition: Sendable {
    case always
    case providerIs(String)
    case fieldEquals(key: String, value: String)
}

public enum Operation: Sendable {
    case copyFile(from: TemplateRef, to: PathTemplate, when: Condition)
    case writeConfig([ConfigEntry], when: Condition)            // upserts KEY=value in .site-config
    case addCSPDomains(fromProvider: Bool, extra: [String], when: Condition)
    case injectAtAnchor(file: PathTemplate, anchor: String, snippet: SnippetTemplate, when: Condition)
}
```

`PathTemplate` / `SnippetTemplate` / `ConfigEntry` support `{{token}}` substitution from
two sources:

- **Answers** — the user's collected input (`[String: String]`; the chosen provider lives
  under the reserved key `provider`).
- **Derived inputs** — values the engine computes up front: `{{brandColor}}` from the
  site's `global.css` `--color-primary`, `{{siteName}}` from the package `Info.plist`. A
  missing source falls back to a documented default and records a `.warning` (never throws).

### How the trio maps onto it

| | booking | donations | giscus |
|---|---|---|---|
| providers | cal / calendly | stripe / liberapay / githubSponsors | — (GitHub) |
| key fields | username, eventSlug?, **style** (choice: inline/floating/button), buttonText? | username/link, buttonText? | repo, repoId, category, categoryId, mapping |
| operations | copyFile `BookingWidget.astro`; inline → copy `/book` page; floating → `injectAtAnchor BaseLayout body-end`; writeConfig `BOOKING_*`; `addCSPDomains(fromProvider)` | copyFile `DonationButton.astro`; copy `/donate` page; writeConfig `DONATIONS_*`; addCSPDomains | copyFile `Comments.astro`; `injectAtAnchor` blog-post layout `comments`; writeConfig `GISCUS_*`; addCSPDomains `giscus.app` |

The booking `style` choice is what flips between a new-file placement (`/book` page) and a
marker-anchor injection (`BaseLayout`) — handled purely by the `when:` conditions, no
per-integration code.

## 5. The scaffolder engine (plan → apply)

Two pure stages with a confirmation gate between them. This split delivers the Siri/FM
confirmation UX, idempotent re-runs, and CI-testable logic.

### Stage 1 — `plan(descriptor, answers, site) → OperationPlan` (pure, no writes)

1. **Validate** answers against `fields` — required present, kind matches (`.email`/`.url`
   format-checked), choice values legal. Returns typed errors, never partial writes.
2. **Compute derived inputs** — read `{{brandColor}}`, `{{siteName}}`; missing source →
   documented default + `.warning`.
3. **Resolve operations** — drop any whose `when:` is false for these answers; substitute
   `{{tokens}}` in paths/snippets/config values; expand `addCSPDomains(fromProvider:)` into
   the chosen provider's `cspDomains`.
4. Emit an **`OperationPlan`**:

```swift
public struct OperationPlan: Sendable, Equatable {
    public let steps: [PlannedStep]   // .createFile(path, bytes)
                                      // .upsertConfig([(key, value)])
                                      // .injectAnchor(file, anchor, block)
                                      // .addCSP([domains])
    public let warnings: [PlanWarning]
}
```

`OperationPlan` is `Equatable` and carries everything needed to render a **human preview**
("Create `src/pages/book.astro`, add 2 domains to CSP, set 4 config keys"). That preview is
exactly the dry-run shown for confirmation.

### Stage 2 — `apply(plan, site) → AsyncStream<SetupStep>` (the only writer)

Runs each step, streaming progress (following the existing `SiteScaffolder`
`AsyncStream<SetupStep>` pattern the wizard already consumes). Every step is **idempotent**:

- **`createFile`** — write/overwrite; skip + `.warning` only if the file exists with
  *different, non-anchor* content the user may have hand-edited (a re-run never silently
  clobbers custom work).
- **`upsertConfig`** — parse `.site-config`, replace-or-append each `KEY`, preserve
  everything else.
- **`injectAnchor`** — the snippet is wrapped in delimiters
  (`<!-- anglesite:booking:start -->…<!-- anglesite:booking:end -->`) inside the anchor
  region; a re-run **replaces the delimited block**, so applying twice yields one copy.
- **`addCSP`** — union into the relevant `.site-config` key; the site's build-time
  `csp.ts` turns it into `_headers`.

### Failure model

A step that throws ends the stream with `.failed(step, message)`; steps already applied
remain (no partial-rollback machinery for v1). Because every step is idempotent,
**re-running the whole plan after fixing the cause converges.** Failures are surfaced, not
hidden (consistent with the "logs are sacred / surface failures" invariants).

## 6. The three front-doors

All three collect answers, call the **same** `plan()` then `apply()`, and differ only in
how they gather input and where the confirmation gate sits.

### GUI wizard (`AnglesiteApp`) — non-technical default

- `@Observable IntegrationWizardModel` with steps: **pick integration → pick provider →
  fill fields → review → apply**.
- The fields step renders **generically from `descriptor.fields`** (`.text` → TextField,
  `.choice` → Picker, `.bool` → Toggle), honoring `visibleWhen` live as provider/choices
  change. No per-integration view code.
- The **review step renders the `OperationPlan` preview** — that *is* the confirmation
  gate. "Create" runs `apply()` and streams progress into the final step.

### App Intents (`AnglesiteIntents`) — typed for natural-language Siri

Per-integration: `AddBookingIntent`, `AddDonationsIntent`, `AddGiscusIntent`. Each is a
thin adapter (`@Parameter` per field, `@Dependency` service, `*Override.scoped` TaskLocal
for tests). `perform()` builds `answers` from its parameters → `plan()` →
**`requestConfirmation(dialog:)` showing the plan summary** (matching the `DeploySiteIntent`
confirm pattern and the #239 edit-confirmation gate) → `apply()`. Returns an
`IntegrationEntity` result + dialog.

### FM chat tool (`AnglesiteCore`)

One shared `SetupIntegrationTool` (conforms to `Tool`, gated `#if compiler(>=6.4)`,
registered on `FoundationModelAssistant` alongside `ApplyEditTool`):

- `@Generable Arguments { integrationType; provider?; config: [String: String] }`.
- `call()` → `plan()`. If required fields are missing, it **returns a prompt string**
  ("Need the Cal.com username to continue") so the model asks the user rather than failing.
- When complete it **does not auto-apply** — it returns the plan summary and applies only
  after the user confirms in chat, keeping parity with the other front-doors'
  confirm-before-write rule.

### Shared seam

A single `IntegrationOperationsService` protocol in `AnglesiteCore`
(`descriptors()`, `plan(...)`, `apply(...)`) is what all three front-doors depend on and
what tests inject — the engine is exercised once and the front-doors stay thin.

## 7. Template change (this repo, app-only)

App-only change to `Resources/Template/` — no paired plugin PR (template changes are
app-owned per CLAUDE.md):

- Add named anchor comments once: `<!-- anglesite:body-end -->` in `BaseLayout.astro` and
  `<!-- anglesite:comments -->` in the blog-post layout. Inert in a site that never runs the
  wizard.
- Confirm `BookingWidget.astro`, `DonationButton.astro`, and `Comments.astro` exist in
  `Resources/Template/` (porting from the plugin template if absent), along with the
  provider CSP wiring already read by `csp.ts`.

## 8. Testing

All in `AnglesiteCoreTests`, Swift Testing `@Test` — runs on CI without a hosted app
(the reason the engine lives in Core).

- **Descriptor validation** — for each descriptor: every `visibleWhen` / `when` references a
  real field/provider key; choice fields have ≥1 choice; provider-driven CSP ops only on
  integrations that declare providers.
- **`plan()` is pure & total** — table-driven over answer sets: required-missing → typed
  error; bad email/URL → validation error; booking `style` inline vs floating yields the
  expected `createFile` vs `injectAnchor` step; provider switch swaps the CSP domain set;
  missing `global.css` → documented `{{brandColor}}` default + `.warning` (not a throw).
- **`OperationPlan` equality / preview** — golden `OperationPlan` per (integration,
  representative answers); asserts the human preview string.
- **`apply()` idempotency** (temp site dir) — apply twice ⇒ one delimited anchor block (not
  two), config keys upserted not duplicated, hand-edited non-anchor file → skip + `.warning`
  rather than clobber.
- **Front-door thinness** — `IntegrationOperationsService` mocked; intent/tool tests assert
  they build correct `answers` and honor the confirm-before-write gate. The hosted GUI
  wizard is not CI-tested (hosted-app CI limitation); its logic is verified through the Core
  service.

## 9. Out of scope (named to bound the plan)

- **Worker-backed integrations + `wrangler secret` management** (contact, newsletter, forms,
  membership) — deferred follow-up spec.
- **Sidecar `apply_edit` reuse** — not needed; marker anchors cover the trio.
- **Integration removal / uninstall** — v1 supports add + idempotent update only.
- **The remaining ~12 integrations** — framework is proven on three; templating the rest is
  later work.
- **Deploy-time CSP enforcement / the §7 native security gate** — separate slice; this only
  writes domains into `.site-config`.

## 10. Front-door / capability summary

| Front-door | Input gathering | Confirmation gate | Module |
|---|---|---|---|
| GUI wizard | generic fields from descriptor | review step renders `OperationPlan` | `AnglesiteApp` |
| App Intent (×3) | typed `@Parameter`s | `requestConfirmation(dialog:)` | `AnglesiteIntents` |
| FM chat tool | `@Generable` args; re-prompts for missing | confirm-in-chat before apply | `AnglesiteCore` |

All converge on `IntegrationOperationsService` → `IntegrationScaffolder.plan` / `.apply`.
