# Add Store — deterministic wizard router

Part of #462 (Slice 3, epic #459 — retiring Claude Code in favor of
deterministic Swift + Apple Intelligence). Ports the plugin's `add-store`
skill (`Anglesite/anglesite/skills/add-store/SKILL.md`) to a Claude-free App
Intent + GUI wizard.

This is the first of four sub-projects covering the bucket's remaining
integrations (`add-store`, then a Cloudflare D1/KV/Workers-script client
paired with a CF-native `contact` provider + `inbox`, then `membership`).
`add-store` was split off first because it needs no new Cloudflare
infrastructure — it's a router over integrations already shipped.

## Why this isn't an `IntegrationDescriptor`

`add-store` never touches a site's `Source/` repo directly. The plugin skill
is a short conversational intake that determines which *other* skill to hand
off to (`buy-button`, `donations`, `snipcart`, `shopify-buy-button`,
`paddle`, `lemon-squeezy`) based on what the owner is selling, how many
items, and whether they need a management dashboard. Each of those targets
already exists as an `IntegrationDescriptor` in `IntegrationCatalog` with its
own fields and operations. Modeling `add-store` as a descriptor itself would
mean unioning five unrelated field sets (`checkoutUrl`, `apiKey`,
`shopDomain`/`storefrontAccessToken`/`productId`, `clientToken`/`priceId`,
…) behind two independent layers of `visibleWhen` conditions the current
`Condition` DSL (`.always`/`.providerIs`/`.fieldEquals`/`.fieldIn`) isn't
shaped for, and would duplicate operations that already exist. `add-store`
is a **router**: it computes which existing integration to open and launches
that integration's existing wizard.

## Scope

- A pure, unit-tested routing function that reproduces the skill's routing
  table (minus the revenue-tracking webhook step below).
- A GUI entry point: an "Add a Store" item in the integration picker that
  opens a short intake (1–2 questions) instead of jumping straight to a
  provider/fields screen, then hands off into the normal wizard flow for the
  resolved integration.
- A Siri-reachable `AddStoreIntent` that asks the same questions
  conversationally, then reuses the existing generic config-string mechanism
  (`SetupIntegrationArguments.parseConfig`) for whatever fields the resolved
  integration still needs — the same pattern the in-chat FM tool already
  uses for integrations without a bespoke typed intent.

**Deferred (follow-up, tracked with the Cloudflare D1/KV/Workers slice):**
the skill's post-routing "webhook setup for revenue tracking" step
(`worker/ecommerce-webhook-worker.js`, per-provider webhook secrets, webhook
URL registration). That's live Cloudflare Worker infrastructure, the same
category of work as `inbox`/`membership`, and doesn't block the routing
itself — a store works without revenue tracking.

## Routing table

Matches the skill's table exactly (see SKILL.md "Routing"), with Stripe
fixed as the service-tier default (the skill only offers Stripe there) and
donations routed to the existing `donations` descriptor rather than handled
inline:

| Category | Follow-up | Target | Preset provider |
|---|---|---|---|
| Service / single offering | — | `.buyButton` | `stripe` |
| Donations / fundraising | — | `.donations` | none (existing wizard asks) |
| Digital downloads | Polar | `.buyButton` | `polar` |
| Digital downloads | Lemon Squeezy | `.lemonSqueezy` | none (no providers) |
| Physical goods | Few (≤ ~10) | `.snipcart` | none (no providers) |
| Physical goods | Full catalog | `.shopifyBuyButton` | none (no providers) |
| Software / SaaS | — | `.paddle` | none (no providers) |

## Architecture

**`AddStoreRouter`** (new file, `AnglesiteCore`) — pure, no I/O:

```swift
public enum StoreCategory: String, CaseIterable, Sendable {
    case service, donations, digitalDownloads, physicalGoods, software
}
public enum DigitalPreference: String, CaseIterable, Sendable { case polar, lemonSqueezy }
public enum CatalogSize: String, CaseIterable, Sendable { case few, catalog }

public enum AddStoreRouter {
    public struct Route: Sendable, Equatable {
        public let integrationID: IntegrationID
        public let presetProvider: String?
    }
    public static func route(
        category: StoreCategory,
        digitalPreference: DigitalPreference? = nil,
        catalogSize: CatalogSize? = nil
    ) -> Route
}
```

`route` is a straight lookup table matching the routing table above;
`digitalPreference`/`catalogSize` are ignored outside their relevant
category (mirrors the skill's "skip this step" conditions). Fully covered by
one test per table row.

**`IntegrationWizardModel`** gains one entry point:

```swift
public func startFromRouter(_ route: AddStoreRouter.Route) {
    selectedID = route.integrationID
    if let provider = route.presetProvider { answers["provider"] = provider }
    step = descriptor?.providers.isEmpty == true || route.presetProvider != nil ? .fields : .pickProvider
}
```

Skips `.pickProvider` whenever the router already resolved the provider
(service/digital-Polar) — the owner already answered "what am I selling",
re-asking "which provider" would be redundant. `.donations`,
`.lemonSqueezy`, `.snipcart`, `.shopifyBuyButton`, `.paddle` have no
providers or an unresolved provider, so they fall through to the existing
step logic unchanged.

**GUI** (`IntegrationWizard.swift`): the picker list gains a leading "Add a
Store" row (distinct styling, e.g. a cart icon), separate from
`descriptorsForPicker`. Tapping it presents a small intake view
(`AddStoreIntakeView`, new file) — a category picker plus the one
conditional follow-up question — with a "Continue" action that calls
`AddStoreRouter.route(...)` and `model.startFromRouter(...)`.

**Siri** (`AnglesiteIntents`): `AddStoreIntent` — `@Parameter`s for `site`,
`category` (`StoreCategory` as `AppEnum`), optional `digitalPreference` /
`catalogSize` (as `AppEnum`s), and an optional free-form `config: String`
(reusing `SetupIntegrationArguments.parseConfig`'s `key=value,key=value`
shape). `perform()`:

1. Compute the route.
2. Merge `parseConfig(config)` with the preset provider (preset provider
   wins if both are somehow supplied).
3. Call `ops.plan(integrationID:answers:siteID:)` — same seam the FM tool
   and other typed intents already use.
4. On `.failure(.missingRequiredField)` / `.providerRequired`, return the
   existing `SetupIntegrationArguments.reply(for:descriptor:)` dialog
   (re-prompt), matching the FM tool's multi-turn pattern — no apply.
5. On success, `requestConfirmation` naming the resolved integration and
   provider, then apply via the existing `applyIntegration` helper.

No new confirmation/dialog vocabulary — reuses `IntegrationDialogs` and
`SetupIntegrationArguments` as-is.

## Testing

- `AddStoreRouterTests` — one case per routing-table row, plus: follow-up
  parameters are ignored outside their category (e.g. `catalogSize` on a
  `service` route has no effect).
- `IntegrationWizardModelTests` — `startFromRouter` lands on `.fields` when a
  provider is preset or the target has no providers, and on `.pickProvider`
  otherwise (`.donations`).
- `AddStoreIntentTests` — pure dialog/routing assertions via the same
  `confirmAndApplyForTesting`-style seam as `AddBookingIntent` /
  `AddDonationsIntent` (bypasses the AppIntents confirmation gate; the gate
  itself isn't testable off-device).

## Non-goals

- No revenue-tracking webhook (deferred, see Scope).
- No "you've outgrown Snipcart, migrate to Shopify" upgrade nudge — that's
  the skill's Step 0 upgrade-detection logic, speculative for a v1 router,
  not requested, and easy to add later without touching this design.
- No new `IntegrationID` or catalog descriptor.
