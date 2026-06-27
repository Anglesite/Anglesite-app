# Design — Site identity h-card (personal + business)

**Date:** 2026-06-27
**Status:** Approved design (drives the implementation plan)
**Issue:** [#388](https://github.com/Anglesite/Anglesite-app/issues/388) — V-1.3 follow-up: `businessProfile` page-singleton (h-card / LocalBusiness), part of V-1 ([#335](https://github.com/Anglesite/Anglesite-app/issues/335)) / epic [#334](https://github.com/Anglesite/Anglesite-app/issues/334)
**Builds on:** V-1.1 content-type registry (#372), V-1.2 personal types (#378), V-1.3 business collection types (#387)

## Context

V-1.3 ([#387](https://github.com/Anglesite/Anglesite-app/issues/387)) shipped the three *collection-backed* business types (announcement / event / review) end-to-end and deferred `businessProfile`, which is structurally different: it is the site's single identity card, not a feed entry. #388 picks that up.

During design we widened the scope by one deliberate step. `businessProfile` is really one half of a more general concept: the IndieWeb **representative h-card** — the single identity that "owns" a site, the anchor for `rel=me` / IndieAuth. That representative h-card is not business-specific; the same `h-card` vocabulary represents *either* a person *or* an organization. The registry today is lopsided: the seven personal types are all `h-entry` *posts*, with no person identity card, while `businessProfile` is the only `h-card`. So this pass builds **both** flavors — personal and business — on one shared singleton mechanism.

## Decisions

These were settled with the owner during brainstorming:

1. **One representative h-card per site (mutually exclusive).** A site has *either* a personal (`Person`) *or* a business (`LocalBusiness`) identity, never both. The "I'm a solo business" case is handled by picking the face the site leads with. Mutual exclusivity is enforced at scaffold time, not in the type model.
2. **Footer-only placement.** The identity renders as a compact h-card in a site-wide footer. No dedicated identity page, no route. This makes it a *representative* h-card (site-wide) and means the profile must be importable everywhere → it lives in a **data module**, not a page's frontmatter. This is a deliberate departure from #388's original "`.page`-stored" framing, which assumed a route under `src/pages`.
3. **Ship empty.** The template does **not** commit a profile, so a fresh, unconfigured site shows no placeholder identity in its footer. The footer partial renders nothing until a profile exists.
4. **Mechanism + template + tests only — no UI.** Creation is exercised through the `AnglesiteCore` API and tests; field-level editing is file-based. No `File ▸ New` command and no per-type SwiftUI editor in this pass.

## Scope

**In:**
- A general **singleton** storage kind in the content-type registry, plus a `personalProfile` descriptor (`h-card` / `Person`) alongside the existing `businessProfile` (`h-card` / `LocalBusiness`), both sharing one identity slot.
- Singleton scaffolding in `AnglesiteCore`: `ContentScaffold.renderSingleton` (pure JSON renderer) and `NativeContentOperations.createTypedSingleton` (write + one-per-site gate + commit).
- A site-wide footer `h-card` partial in the template, rendering whichever profile is configured (or nothing).
- Tests across all of the above, including a build-backed render smoke test for both flavors.

**Out (own follow-ups):**
- Per-type SwiftUI editor — V-1.4 ([#346](https://github.com/Anglesite/Anglesite-app/issues/346)).
- schema.org `LocalBusiness` / `Person` JSON-LD — V-1.8 ([#350](https://github.com/Anglesite/Anglesite-app/issues/350)). This pass emits **microformats2 only**.
- `rel=me` / IndieAuth site-identity wiring — V-2.
- Any UI affordance to create or edit the identity.

## Design

### 1. Registry — a third storage kind and a new descriptor

A representative h-card is neither a route page nor a collection, so `ContentStorage` gains a third case:

```swift
public enum ContentStorage: Sendable, Equatable {
    case page
    case collection(String)
    case singleton(String)   // one record per site; the String is the shared slot name
}
```

with a `singletonSlot` computed property mirroring the existing `collection`:

```swift
public var singletonSlot: String? {
    if case let .singleton(name) = storage { return name }
    return nil
}
```

- `businessProfile.storage` changes from `.page` to `.singleton("profile")`; the rest of that descriptor is unchanged.
- A new `personalProfile` descriptor is added to `businessTypes`' sibling set (it is a site-identity type, declared next to `businessProfile`):

```swift
static let personalProfile = ContentTypeDescriptor(
    id: "personalProfile",
    displayName: "Personal Profile",
    storage: .singleton("profile"),
    fields: [
        ContentTypeField("name", .string, required: true),
        ContentTypeField("description", .text),
        ContentTypeField("email", .string),
        ContentTypeField("url", .url),
        ContentTypeField("photo", .image),
    ],
    projections: ContentTypeProjections(
        microformat: "h-card",
        microformatProperties: [
            "name": "p-name",
            "description": "p-note",
            "email": "u-email",
            "url": "u-url",
            "photo": "u-photo",
        ],
        schemaType: "Person"
    )
)
```

Both profiles use the **same slot** (`"profile"`), which is what makes them mutually exclusive: there is one identity file per site, and whichever type wrote it owns the slot.

**Why mf2 rendering stays uniform.** In microformats2, a person and a business are both just `h-card`; the only difference is *which properties appear* (a business has `p-adr`/`p-tel`; a person does not). The `Person` vs `LocalBusiness` distinction is a schema.org `@type` concern, which is V-1.8. So in this pass the two descriptors differ only in their **fields** and their (forward-looking) `schemaType` — the renderer treats them identically.

### 2. Storage format — one JSON data module

The profile is a single JSON file at **`src/data/profile.json`** (the shared slot). Shape:

```json
{
  "type": "businessProfile",
  "name": "",
  "description": "",
  "telephone": "",
  "email": "",
  "streetAddress": "",
  "locality": "",
  "region": "",
  "postalCode": "",
  "hours": [],
  "url": ""
}
```

- `"type"` records the originating descriptor id. Everything downstream — the schema.org `@type` in V-1.8 — is derivable from it via the registry, so no other discriminator is stored.
- Keys follow descriptor field order; the `markdown` body field (a data record has none) is excluded.
- **Not committed to the template.** The template ships without `src/data/profile.json` (decision 3).

### 3. Rendering — a site-wide footer h-card

- **New `src/components/Hcard.astro`.** Optionally loads the profile with the standard Vite "optional import" idiom:

  ```ts
  const mods = import.meta.glob<{ default: Record<string, any> }>(
    "../data/profile.json", { eager: true });
  const profile = Object.values(mods)[0]?.default;
  ```

  When the file is absent the glob returns `{}` and the component renders nothing (decision 3). When present it renders a `div.h-card` emitting, for whatever fields exist: `p-name`, `p-note` (description), `p-tel` (telephone), `u-email`, a nested `p-adr h-adr` block (`p-street-address` / `p-locality` / `p-region` / `p-postal-code`), `u-url`, and `u-photo`. `hours` renders as a plain `<ul>` with **no** mf2 class — h-card has no opening-hours property, so per the descriptor's existing comment hours are carried by schema.org (V-1.8) only.

- **`BaseLayout.astro`** gains a `<footer>` that renders `<Hcard />`, so the identity appears site-wide on every page that uses the base layout.

### 4. Scaffolding — `AnglesiteCore`, no UI

- **`ContentScaffold.renderSingleton(descriptor:name:)` → `String`.** Pure, deterministic JSON: `"type"` first, then one key per non-`markdown` field in descriptor order, with empty/`0`/`false`/`[]` defaults and the `name`-like field filled from the passed name. Two-space indentation, trailing newline. A new `ContentScaffold.singletonRelativePath(slot:)` returns `src/data/<slot>.json`.

- **`NativeContentOperations.createTypedSingleton(siteID:typeID:name:registry:)`.** Resolves the descriptor's `singletonSlot` (failing for non-singleton types), computes `src/data/<slot>.json`, **refuses if that file already exists** ("A site identity already exists" — the mutual-exclusivity gate, which fires across both kinds because they share the slot), renders via `renderSingleton`, writes it, and commits best-effort through the same git closure as `createTyped`.

- **`createTyped`** continues to handle only collection-backed types; its rejection message generalizes from the `.page`-specific wording to "… is not a collection type; use createTypedSingleton". The existing `createTypedPageStored` test updates to the new message and the `.singleton` storage.

### 5. Tests

- **Registry** (`ContentTypeRegistryTests`): `personalProfile` is present; both profiles report `.singleton("profile")` and `h-card`; `schemaType`s are `Person` / `LocalBusiness`; `singletonSlot` works.
- **Scaffold** (`ContentScaffoldTests`): `renderSingleton` for `businessProfile` (address keys + `"hours": []`, `name` filled) and for `personalProfile` (no address keys); output is deterministic and ends in one newline.
- **Operations** (`NativeContentOperationsTests`): `createTypedSingleton` writes `src/data/profile.json` and commits; a **second** create (business then person) is refused with the identity-exists message; it rejects collection types; `createTyped` rejects singleton types with the generalized message.
- **Render smoke** (new `SiteIdentityRenderSmokeTests`, gated on `buildable`, serialized under `TemplateBuildSerializer.shared`): write a business `profile.json` fixture into the template → `astro build` → a built page's footer HTML contains `h-card` / `p-name` / `p-tel` / `p-street-address`; swap the fixture to a person profile → rebuild → footer contains `h-card` / `p-name` / `u-email` and **no** `p-street-address`. The fixture is `defer`-removed so the template stays ship-empty. Optionally assert the absent-file → no-`h-card` empty state before writing any fixture.

### 6. Unchanged / non-goals

- **Drift guard untouched.** `ContentConfigDriftTests` iterates collection-backed types only (it skips any descriptor whose `collection` is `nil`). Both singletons have `collection == nil`, so they are skipped and the guard still passes with no change. The data module is not a Zod collection and is intentionally outside the guard's remit, per #388's note.
- **No new public surface beyond the registry case and the two `AnglesiteCore` methods.** No protocol change to `ContentOperationsService` (the new method lives on the concrete `NativeContentOperations`); no app-target / SwiftUI code.

## Coordination risk

`businessProfile`'s storage changes from `.page` to `.singleton("profile")`. Adding a `ContentStorage` case is a public-enum change: any exhaustive `switch` over `ContentStorage` elsewhere would fail to compile until it handles `.singleton`. The implementation must grep for such switches first (the known consumers — `descriptor.collection`, the `New Collection` sheet's `collection != nil` filter — use the computed property, not a raw switch, so they are unaffected, but this must be verified, not assumed).

## Acceptance

- `personalProfile` and `businessProfile` are both `.singleton("profile")` / `h-card` registry types.
- `createTypedSingleton` writes `src/data/profile.json`, commits, and refuses a second identity of either kind.
- A configured business profile renders an h-card footer with `p-tel` + `p-adr`; a configured personal profile renders an h-card footer without address properties; an unconfigured site renders no footer h-card. Proven by a real `astro build` in the render smoke test.
- The drift guard and the seven personal + three business collection types still build and render unchanged; full `swift test` is green.
