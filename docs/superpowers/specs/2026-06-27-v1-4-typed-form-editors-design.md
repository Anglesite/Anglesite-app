# V-1.4: Per-type SwiftUI form editors — design

**Issue:** [#346](https://github.com/Anglesite/Anglesite-app/issues/346) (part of [#335](https://github.com/Anglesite/Anglesite-app/issues/335), V-1)
**Date:** 2026-06-27
**Status:** Approved (brainstorm)

## Goal

Give each typed content object a structured **form** editor in the app. Opening a
typed content file (a note, article, photo, event, …, or the business profile)
shows purpose-built form controls — date pickers, image pickers, in-reply-to URL
fields, an hours list — instead of raw markdown. Edits round-trip to YAML
frontmatter without data loss and produce a per-edit git commit, exactly like the
existing text/MCP edit paths.

**Acceptance (from #346):** each type has a form editor; round-trips to
frontmatter; per-edit git commit preserved.

## Approach

The content-type registry (`ContentTypeRegistry`,
`Sources/AnglesiteCore/ContentTypeRegistry.swift`) already encodes every type's
fields and their `Kind` (`string`, `text`, `markdown`, `bool`, `date`,
`datetime`, `url`, `image`, `number`, `stringArray`, `imageArray`). Every example
in the issue maps onto an existing `Kind`:

| Issue example | Kind |
|---|---|
| photo picker | `image` |
| date + location for Event | `datetime` + `string` |
| in-reply-to URL for Reply | `url` |
| hours for Business Profile | `stringArray` |

So a **single schema-driven editor** that renders one control per `Kind` covers
all types from the registry. New types get an editor for free. No bespoke
per-type views.

Decisions locked during brainstorming:

- **Schema-driven, not bespoke per-type.**
- **Form-only for typed files.** No in-app form↔source toggle. Raw source stays
  reachable on disk / external editor, consistent with "git is the source of
  truth." This makes round-trip safety mandatory (below).
- **All 11 types**, including `businessProfile` — whose on-disk location is
  decided here (§3).

## Components

### 1. `FrontmatterDocument` (AnglesiteCore) — the keystone

A new pure, I/O-free value type that models a content file as:

- **ordered** frontmatter entries (key → raw value), and
- the **body** text that follows the closing `---` fence.

Responsibilities:

- **Parse** a file string into ordered entries + body.
- **Typed get/set** of a field's value, keyed by field name.
- **Serialize** back to a string that **preserves key order, unknown keys not in
  the type schema, and the body verbatim**, and preserves the original line
  ending (LF/CRLF).

Value representation preserves the raw scalar text per key (so untouched fields
serialize byte-identically) plus arrays. The form layer converts to/from
`Date`/`Bool`/number based on the field's `Kind`; only fields the user actually
edits are rewritten.

Why additive rather than reusing `Frontmatter.parse`: the existing parser is
read-only, parses top-level keys only, drops unknown keys, and collapses values
to `.string`/`.bool`/`.array`. That is lossy and unsafe for write-back. The
existing parser stays for its current read-only consumers; `FrontmatterDocument`
is the read/write path. It may share low-level scalar/array parsing helpers where
practical, but owns serialization.

### 2. Type resolution (FileRef → `ContentTypeDescriptor`)

- **Collection types (10):** a file under `src/content/<collection>/` resolves to
  the descriptor whose `collection` equals `<collection>`. Directory-based, zero
  ambiguity, matches Astro's content-collection layout.
- **`businessProfile` singleton:** resolved by a `type: businessProfile`
  frontmatter marker — filename-independent and robust.

Resolution is a pure function in AnglesiteCore taking the file's project-relative
path and (for the singleton) parsed frontmatter, returning an optional
descriptor.

### 3. `businessProfile` on-disk location

Ship a singleton markdown page in the template at **`Resources/Template/src/pages/about.md`**
carrying `type: businessProfile` plus the business fields in YAML frontmatter.
This:

- satisfies the descriptor's `storage: .page`,
- round-trips through `FrontmatterDocument` like any other typed file,
- exists in the navigator for every newly scaffolded site,
- gives #388's h-card / LocalBusiness **rendering** a stable file to build on
  later — this PR settles *location only*, not rendering.

This intentionally absorbs the editor-relevant slice of #388. The PR will say so.

### 4. `TypedEntryEditorModel` (AnglesiteApp)

`@MainActor`, `@Observable`, `final class`, paralleling `FileEditorModel`:

- `init(file:descriptor:)`
- `load()` — reads off-main via `FileDocumentIO.load`, parses into a
  `FrontmatterDocument`, exposes field bindings + the body.
- `save()` — applies edited values back into the document, serializes, writes
  off-main via `FileDocumentIO.save`, then git-commits.
- Reuses the existing dirty-tracking, `flushBeforeLeaving()`,
  `checkExternalChange()`, and conflict-resolution machinery from the
  `FileEditorModel` pattern (external edits to the same file must not be
  clobbered).

### 5. `TypedEntryEditorView` (AnglesiteApp)

Renders a SwiftUI `Form` from `descriptor.fields`, one control per `Kind`:

| Kind | Control |
|---|---|
| `string`, `url` | `TextField` |
| `text` | multi-line `TextField` (`axis: .vertical`) |
| `markdown` (`body`) | `TextEditor` |
| `bool` | `Toggle` |
| `date`, `datetime` | `DatePicker` |
| `number` | `TextField` + number formatter |
| `image` | path `TextField` + "Choose…" file picker |
| `stringArray` (hours, tags) | editable add/remove row list |
| `imageArray` (album) | editable list of image pickers |

Required fields are marked; the body (`markdown`) renders last as a full-width
editor. Field order follows the descriptor.

### 6. Wiring

`EditorKind.resolve(for:)` currently takes only a `FileRef` and returns
`.text`/`.plist`. Typed-content detection needs project context (registry +
project root), so the typed-form branch is selected where that context is
available — in `SiteWindow.applyNavigatorSelection(_:)`, mirroring the existing
`.plist` branch. When resolution returns a descriptor, the main pane hosts
`TypedEntryEditorView`; otherwise it falls back to the existing
`MainPaneEditorView` (`.text`).

### 7. Per-edit git commit

`save()` calls `NativeContentOperations.processGitCommit(projectRoot, relPath, message)`
with message `anglesite: edit <type> <slug>`, reusing the exact stage/commit path
used by content creation. Best-effort (returns the new HEAD SHA or nil), matching
existing behavior.

## Data flow

```
open typed file
  → resolve descriptor (path for collections; frontmatter marker for businessProfile)
  → TypedEntryEditorModel.load(): FileDocumentIO.load → FrontmatterDocument.parse
  → TypedEntryEditorView renders Form from descriptor.fields
  → user edits fields / body
  → save(): apply edits → FrontmatterDocument.serialize (unknown keys + body preserved)
           → FileDocumentIO.save → processGitCommit
```

## Error handling

- **Load failure / unreadable file:** surface via the model's load-error state,
  same as `FileEditorModel`.
- **External change while editing:** reuse the conflict path
  (`checkExternalChange`, keep-mine / reload-from-disk).
- **Serialization safety:** untouched fields and unknown keys serialize
  unchanged; the body is preserved verbatim. A round-trip of an unedited document
  is the identity.
- **Commit failure:** best-effort; a failed commit does not block the save (the
  file is still written), matching `processGitCommit` semantics.
- **Malformed frontmatter:** degrade gracefully — if a file can't be parsed into
  a document, fall back to the text editor rather than risk data loss.

## Testing

- **`FrontmatterDocument` round-trip (unit):** identity on unedited documents;
  unknown keys preserved across edits; body preserved verbatim; each `Kind`'s
  value formatting; LF/CRLF preservation; key-order stability.
- **Type resolution (unit):** collection path → descriptor; `businessProfile`
  marker → descriptor; unrelated file → nil (text fallback).
- **`TypedEntryEditorModel` (unit):** load → edit → save writes expected bytes;
  commit invoked with expected relPath/message (injected git-commit closure);
  external-change conflict handled.

Logic lives in AnglesiteCore + the model so it is testable under `swift test`
without a hosted app target (consistent with the repo's CI constraints).

## Scope discipline (out of scope)

- h-card / schema.org JSON-LD **rendering** of the business profile or any type —
  that is V-1.7 (#349), V-1.8 (#350), and #388's rendering work. This PR ships
  the editor and the businessProfile *file location* only.
- Form ↔ raw-source toggle (form-only was chosen).
- App-Intent entities for the new types — V-1.9 (#351).

## Files (anticipated)

New:
- `Sources/AnglesiteCore/FrontmatterDocument.swift`
- `Sources/AnglesiteCore/ContentTypeResolver.swift` (path/marker → descriptor)
- `Sources/AnglesiteApp/TypedEntryEditorModel.swift`
- `Sources/AnglesiteApp/TypedEntryEditorView.swift`
- `Resources/Template/src/pages/about.md` (businessProfile singleton)
- Tests under `Tests/AnglesiteCoreTests/` for document + resolver + model.

Modified:
- `Sources/AnglesiteApp/SiteWindow.swift` (editor routing branch)
- possibly `Sources/AnglesiteCore/EditorKind.swift` (typed-form case, if it
  improves the routing seam)
