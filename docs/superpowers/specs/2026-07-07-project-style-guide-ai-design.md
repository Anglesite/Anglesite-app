# Project Style Guide & AI Consistency — Design

Tracking issue: [#313](https://github.com/Anglesite/Anglesite-app/issues/313).

## Summary

Anglesite learns a site's writing, image, component, naming, and SEO conventions
directly from its existing content, and feeds that learned "project conventions"
context into on-device generation so AI-produced content matches the rest of the
site instead of reading generically. A "Project Style Guide" view lets the owner
inspect what was learned and override individual fields.

## Motivation

Every site develops its own voice, terminology, and formatting conventions.
Today, generated content (e.g. alt text) is produced from a generic prompt and
often needs manual editing to match. Rather than hand-tuning prompts per site,
Anglesite should infer conventions from the repository itself and apply them
automatically.

This design responds to the issue author's own follow-up comment, which
broadened "Project Style Guide" into a general "Project Intelligence" layer
intended to be consumed by multiple AI features over time. This spec designs
that general layer, but scopes the first implementation slice narrowly (see
"Non-goals" and "First consumer").

## Scope & taxonomy

| Category | Treatment in this design |
|---|---|
| Writing tone, terminology/glossary | New — inferred (stats + on-device FM) |
| Markdown/callout/list conventions | New — inferred (deterministic stats) |
| Heading hierarchy, naming/slug patterns | New — inferred (deterministic stats) |
| Image conventions (alt style, placement) | New — inferred (deterministic stats + FM tone) |
| Component usage patterns | New — inferred (deterministic scan of `.astro` usage) |
| SEO patterns (meta description length/style) | New — inferred (deterministic stats) |
| Frontmatter / content-collection schemas | **Not learned** — read as ground truth from `src/content.config.ts` (Zod). This intentionally stays aligned with the content-type-registry work in the personal-publishing-OS pivot plan (task 1.1) rather than duplicating it. |
| Design conventions (colors, spacing, layout tokens) | **Deferred** — out of scope. Needs a different extraction approach (CSS/theme tokens, not content text) and is left for a future slice. |

Everything in the "New" rows is modeled as one `ProjectConventions` value with
sub-sections per category, so consumers and the Style Guide view see one
coherent object rather than N unrelated stores.

## Data model

```swift
public struct ProjectConventions: Sendable, Codable, Equatable {
    public var writing: WritingConventions
    public var frontmatter: FrontmatterConventions   // read from content.config.ts, not inferred
    public var components: ComponentConventions
    public var images: ImageConventions
    public var naming: NamingConventions
    public var seo: SEOConventions
    public var lastLearnedAt: Date?
}
```

Each inferred leaf field is wrapped in a generic that carries provenance:

```swift
public struct Learned<Value: Sendable & Codable & Equatable>: Sendable, Codable, Equatable {
    public var value: Value
    public var source: Source        // .inferred(confidence: Double) | .userOverride
    public var sampleSize: Int?      // e.g. how many files this was inferred from
}
```

**Invariant:** re-learning never overwrites a `.userOverride` field. The
engine's rebuild pass only ever produces `.inferred` values; a merge step
(keyed by field path) preserves any field the user has overridden before the
result is persisted. Low `sampleSize` values let the Style Guide view show a
"low confidence" indicator rather than asserting a rule from too little
evidence (e.g. a brand-new site with two pages).

Example category:

```swift
public struct ImageConventions: Sendable, Codable, Equatable {
    public var altTextAverageLength: Learned<Int>
    public var altTextEndsWithPunctuation: Learned<Bool>
    public var toneDescriptors: Learned<[String]>       // FM-derived, e.g. ["concise", "descriptive"]
    public var brandTerms: Learned<[String]>            // canonical capitalization, e.g. "Anglesite" not "anglesite"
}
```

`FrontmatterConventions` holds the collection/field data read from
`content.config.ts` (see "Frontmatter reading" below) with no `Learned<T>`
wrapper, since it is ground truth rather than inference and is not
user-overridable.

## Learning engine

A per-site actor mirroring the shape of the existing `SiteKnowledgeIndex` /
`SpotlightIndexer` pattern:

```swift
public actor ProjectConventionsEngine {
    public func rebuild(siteID: String, projectRoot: URL) async
    public func upsertFile(siteID: String, projectRoot: URL, relativePath: String) async
    public func removeFile(siteID: String, relativePath: String)
    public func conventions(siteID: String) -> ProjectConventions?
    public func applyOverride(siteID: String, keyPath: PartialKeyPath<ProjectConventions>, value: Any) async
    public func clearOverride(siteID: String, keyPath: PartialKeyPath<ProjectConventions>) async
}
```

(The `keyPath`/`value` signature above is illustrative — the implementation
plan should pick a concrete, type-safe encoding, e.g. an enum of overridable
fields rather than `PartialKeyPath`/`Any`, since Swift key paths don't erase
cleanly through `Codable` boundaries.)

**Two-pass extraction:**

1. **Deterministic scan (always runs, cheap).** Walks the same file set
   `SiteKnowledgeIndex` does, reusing `SiteIndexPaths`'s skip rules, and
   computes pure statistics: heading capitalization style, list-marker style,
   frontmatter key frequency per content kind, `.astro` component usage
   counts, alt-text lengths/punctuation, filename/slug patterns,
   meta-description lengths. No model calls, so this can run on every
   debounced file-change batch.
2. **FM enrichment (throttled).** A separate, coarser-cadence pass that
   samples body text and asks the on-device Foundation Model
   (`FoundationModelAssistant(tier: .onDevice)`, guided/structured
   generation) to produce a handful of short descriptive fields: tone
   adjectives, and a normalized brand-terms list distilled from the raw
   frequency data. This only re-runs periodically (e.g. after N deterministic
   rebuilds or a time floor such as 5 minutes) since it is model-call cost,
   not file-parse cost — frequent small edits should not repeatedly invoke
   Foundation Models.

**Triggering:** reuses the existing `SiteFileWatcher` → `KnowledgeReindex`
pipeline. `FSEventsFileWatcher`'s 0.3s coalescing already acts as the
debounce; `KnowledgeReindex.apply` is extended to also drive
`ProjectConventionsEngine` alongside `SiteKnowledgeIndex`, using the same
`needsFullRescan` signal for full-rebuild-vs-incremental-upsert decisions. No
new file-watching subsystem is introduced.

In addition, the Style Guide view (see below) exposes a manual "Rescan now"
action that forces an immediate full pass (both deterministic and FM) outside
the normal debounce/throttle cadence.

## Storage

`Config/conventions.json`, one record per site — app-owned, not git-tracked,
alongside the existing `chat-history.jsonl` pattern. Written after each
rebuild pass, with the override-preserving merge applied before the write.

## Frontmatter reading

Rather than parsing TypeScript/Zod from Swift, a small script
(`scripts/describe-content-schema.ts`) is added to the site template. It
imports `content.config.ts` and emits collection names + field
names/types as JSON. The Swift engine invokes it over the same MCP/container
channel already used for other deterministic Node-side operations (no new
subprocess-spawning path) and stores the result verbatim as
`FrontmatterConventions`. If the script is absent or fails (e.g. a site
predating content-schema registration), `frontmatter` is left empty — this
never blocks the rest of the rebuild.

## Consumption pattern

Two ways consumers use the engine, both already precedented in the codebase:

1. **Structured accessors** — typed getters like
   `conventions.images.brandTerms.value`, for consumers that build their own
   prompts. This is what the first consumer (below) uses.
2. **Freeform guidance text** — `formattedGuidance(siteID:)`, analogous to
   `SiteKnowledgeIndex.formattedContext(siteID:query:)`, producing a short
   natural-language style-guide block. Not consumed by anything in this slice,
   but the mechanism is general so `KnowledgeAugmentedAssistant` (chat) or
   `FoundationModelPageCopyGenerator` (new-page copy) can adopt it later
   without new plumbing.

### First consumer: `AltTextGenerator`

`AltTextGenerator` already takes an injected `Producer` closure
(`@Sendable (imageURL, context) async throws -> GeneratedAltText`). Its
production wiring gains a `ProjectConventionsEngine` dependency; the `produce`
closure builds the vision-model prompt with a preamble drawn from
`conventions.images` and `conventions.writing` terminology (canonical brand
terms, average length/punctuation style) before calling
`FoundationModelAssistant.generateStructured`. When no conventions have been
learned yet (new site, or the engine hasn't run), the preamble is simply
omitted — `AltTextGenerator`'s existing best-effort/swallow-failure behavior
is unchanged.

## Project Style Guide view (UI)

The app already has an "Inspector" concept — the per-page contextual panel
(`PageInspectorView`, tied to `model.inspectorContext`, toggled via the
existing `sidebar.right` toolbar button). The Project Style Guide is a
different kind of surface (whole-project, not per-selection), so it follows
the pattern used for other whole-site views — **Audit**, **Dependency
Update**, **Integration Wizard** — which are `.sheet(item:)` presentations
off an `@Observable` model on `SiteWindowModel`, not the page-level Inspector
panel.

**Model:**

```swift
@Observable @MainActor
final class ProjectConventionsModel {
    var conventions: ProjectConventions?
    var isLearning: Bool = false

    func rescan() async
    func setOverride(_ field: OverridableField, value: OverrideValue) async
    func clearOverride(_ field: OverridableField) async
}
```

**View (`ProjectStyleGuideView`):** a sectioned list — Writing, Images,
Components, Naming, SEO, Frontmatter — each row shows the learned value, a
confidence indicator ("learned from 12 pages" vs. "low confidence — only 2
pages"), and an edit affordance that flips the field to `.userOverride`
(with a way to revert back to the learned value). Frontmatter is read-only —
no edit affordance — since it is read from `content.config.ts`, not
inferred.

**Presentation:** `SiteWindowModel.styleGuideModel` (item-based sheet, same
shape as `dependencyUpdateModel` / `integrationWizardModel`), triggered by a
new toolbar button.

## Testing

`ProjectConventionsEngine` follows the existing fake-backend-testable pattern
(`SiteKnowledgeIndex`, `SpotlightIndexer`): unit tests drive
`rebuild`/`upsertFile` against fixture directories and assert on the
resulting `ProjectConventions`, with no live FM or file-watcher required. The
FM enrichment pass is injected as a closure (matching
`AltTextGenerator.Producer`) so it is fakeable in tests.
`AltTextGenerator`'s existing tests gain cases for "conventions present" vs.
"conventions absent / engine never learned." `ProjectConventionsModel` and
`ProjectStyleGuideView` are tested the same way `HealthModel`/`AuditModel`
and their sheets are — model logic unit-tested, view wiring smoke-tested.

## Non-goals

- Design/CSS/theme conventions (colors, spacing) — deferred to a future slice.
- Wiring conventions into chat, new-page copy, or deploy summaries — the
  mechanism (see "Consumption pattern") supports it, but only
  `AltTextGenerator` is wired in this slice.
- Cross-site conventions or shared defaults — each site's conventions are
  independent.
- Git-tracked/synced conventions — storage is app-local (`Config/`) per this
  design; revisit if contributors outside the app need visibility into
  learned conventions.
