# Spike — How Anglesite actually exposes operations to macOS 27 system AI

**Issue:** [#235](https://github.com/Anglesite/Anglesite-app/issues/235) (parent [#135](https://github.com/Anglesite/Anglesite-app/issues/135), Phase D — System-wide MCP exposure)
**Date:** 2026-06-18
**Depends on:** D.1 audit ([#162](https://github.com/Anglesite/Anglesite-app/issues/162)) — [`2026-06-17-d1-intent-mcp-readiness-audit.md`](2026-06-17-d1-intent-mcp-readiness-audit.md); D.2 ([#163](https://github.com/Anglesite/Anglesite-app/issues/163)) — [`2026-06-17-d2-mcp-tool-descriptors-design.md`](2026-06-17-d2-mcp-tool-descriptors-design.md)
**Status:** spike findings — answers the registration-mechanism question [#101](https://github.com/Anglesite/Anglesite-app/issues/101) left open

## Why this spike exists

#235 (and the Phase D spec's D.2 code sketch) assume Anglesite registers custom MCP
tools imperatively:

```swift
// docs/superpowers/specs/2026-06-11-siri-ai-integration-design.md — D.2 (placeholder)
MCPToolRegistry.register(name: "anglesite_apply_edit", inputSchema: …, handler: { … })
```

The D.1 audit already suspected this API does not exist (it found the platform
`mcpbridge` **auto-derives** tools from App Intent schema). #235 and #164 (D.3 — call
`AnglesiteMCPRegistration.register()` in `bootstrap()`) still rest on the imperative
premise. Before building that type, this spike verifies what the **shipping Xcode 27 /
macOS 27 SDK** actually offers.

## Method

Direct inspection of the installed SDK
(`Xcode-beta.app`, Xcode 27.0, `MacOSX.sdk`):

- Grepped every framework `.swiftinterface` under `MacOSX.sdk/System/Library/Frameworks`
  for MCP registration symbols.
- Inspected the `mcpbridge` binary (`--help`, `otool -L`).
- Read the `AppIntents.framework` macOS interface for the assistant-schema surface.

## Finding 1 — There is no imperative MCP tool-registration API. At all.

| Probe | Result |
|---|---|
| `MCPToolRegistry` / `registerTool` / `register(name:handler:)` in `AppIntents.framework` | **absent** |
| Same symbols across *every* macOS SDK framework interface | **absent** |
| Entitlement / Info.plist key for an app-hosted MCP server | **absent** |
| `mcpbridge` binary | exists at `…/Developer/usr/bin/mcpbridge`, but its `--help` says **"STDIO Bridge for *Xcode* MCP Tools"** — it connects to a running Xcode instance (`MCP_XCODE_PID`) and forwards JSON-RPC to *Xcode's* tool service (build, `run-agent`, skills export). It is **not** a third-party-app registration surface and links no app-facing MCP framework. |

**Conclusion:** the `MCPToolRegistry.register(handler:)` shape in the spec is a
placeholder Apple never shipped. A literal `AnglesiteMCPRegistration.register()` that
hand-registers custom tools with handlers **cannot be written** — the symbol does not
exist and the code would not compile. #235's original framing is not implementable, and
#164 D.3 as literally worded ("add the `register()` call") has nothing real to call.

## Finding 2 — The real exposure mechanism is declarative *assistant-schema conformance*

macOS 27 exposes app actions to the system assistant (and, per Apple's WWDC26
system-wide-MCP story, the agent surface that rides on it) **declaratively**, by
conforming intents/entities/enums to a **fixed catalog of Apple-defined schemas**:

- `@AssistantIntent(schema:)` / `@AssistantEntity(schema:)` — Apple's predefined
  `AssistantSchemas` domains.
- `@AppIntent(schema:)` / `@AppEntity(schema:)` / `@AppEnum(schema:)` (macOS 15+) — the
  `AppSchema` family. The macro conforms the type to `AssistantSchemaIntent`, so an
  app-schema intent is bridged into the same assistant surface.

The OS auto-derives the tool/parameter schema from this conformance. There is **no**
imperative seam — you describe the operation by *matching a known shape*, you do not
register a handler.

### Apps cannot mint arbitrary schemas

`AppSchema.Intent(_ identifier: String)` has an **`internal`** initializer. Apps don't
invent schema identifiers; they conform to one of Apple's predefined **kinds**. The
macOS 27 catalog (from the SDK interface):

> Messages, ImageGeneration, **WordProcessor**, Audio, Photos, Reminders, Whiteboard,
> Clock, Spreadsheet, Notes, **Browser**, Calendar, Mail, …

macOS 27 is actively *expanding* this catalog (e.g. `AppSchema.MessagesIntent` is new at
`@available(macOS 27.0)`), but it remains a closed, Apple-owned set.

## Finding 3 — `WordProcessor` is a strong fit for Anglesite's content-authoring half

The `WordProcessor` schema is built for page/document authoring apps, and Anglesite is
fundamentally one. From the SDK interface:

| `WordProcessor` schema member | Kind | Anglesite analog |
|---|---|---|
| `createPage` | intent | **`AddPageIntent`** — direct |
| `openPage` | intent | **`PreviewSiteIntent`** (page-level) — direct |
| `create` | intent | new-site / new-document |
| `open` | intent | open site / preview |
| `addImageToPage` / `addTextBoxToPage` / `addVideoToPage` | intent | content insertion (overlaps `EditContentIntent`) |
| `document` | entity | a site (or page collection) |
| `template` | entity | **Anglesite's `Resources/Template/`** |
| `page` | entity | **`PageEntity`** |

`Browser` (search / createTab / openURLInTab / bookmark; entities tab/bookmark/window) is
a **weak** fit — it models a web browser navigating the web, not previewing one's own
site. Map `PreviewSiteIntent` via `WordProcessor.openPage`, not Browser.

### What maps to nothing

`DeploySiteIntent`, `BackupSiteIntent`, `AuditSiteIntent` are Anglesite-specific dev-ops
with **no** Apple schema analog. They stay as plain `AppIntent`s — still reachable via
Siri / Shortcuts / Spotlight and still surfaced to the auto-derived agent schema (per
D.1/D.2), just not assistant-schema-*typed*. That is the expected, correct outcome, not a
gap to force-fit.

## Implications for #235 / #164 / D.2

- **D.2's "defer custom descriptors as YAGNI" decision is now SDK-confirmed**, not just a
  judgement call: there is no descriptor/registration API to adopt. The auto-derivation
  path the D.1/D.2 enrichments target is the *only* path.
- **#235 should be re-scoped or closed.** Its hand-written-descriptor + `AnglesiteMCPRegistration`
  premise is impossible. The defensible work it points at splits into two real, separable
  pieces:
  1. **(Recommended next) Adopt `WordProcessor` schema conformance** for the
     content-authoring intents/entities (`AddPageIntent`→`createPage`,
     `PreviewSiteIntent`→`openPage`, `PageEntity`→`page`, plus `document`/`template`).
     This is the genuine "richer system-AI exposure" win and is a real, reviewable feature.
  2. The **operation-metadata / confirmation-invariant** value (side-effect level,
     confirmation, cancellability) that #235 also gestured at is *not* an MCP concern — it
     belongs to **#239** (confirmation gates) and **#236** (readiness diagnostics) as an
     internal, testable registry. Keep it there; don't reintroduce it as a parallel MCP
     surface.
- **#164 D.3 should be reframed.** There is no `register()` to wire. If we adopt
  `WordProcessor` schemas, bootstrap wiring is unnecessary (conformance is compile-time);
  D.3's remaining honest content is the **unit test** that asserts the intended intents
  carry the expected schema conformance.

## Cost / risk of adopting `WordProcessor` schemas (for the follow-on design)

- **Required-shape conformance.** Apple's schema fixes each intent's required parameters
  and return shape. Adopting `createPage` means `AddPageIntent` must match that signature
  (parameter names/types Apple dictates), which is likely a non-trivial refactor of the
  current intents — needs a per-intent diff against the schema's required members before
  committing.
- **Verification gate.** Conformance correctness can only be fully proven on a macOS 27
  device with the assistant surface; unit tests can assert the conformance compiles and the
  macro-generated members exist, but end-to-end exposure lands on the D.5 (#166) manual
  smoke.
- **Both targets must build** (`Anglesite` + `AnglesiteMAS`) per CLAUDE.md — schema macros
  change the derived metadata, so prove the `.app` links, not just `swift test`.

## Recommendation

1. **Re-scope #235** from "hand-written MCP descriptors" to **"adopt `WordProcessor`
   assistant-schema conformance for content-authoring intents/entities."** Close the
   imperative-registration premise as SDK-confirmed-impossible.
2. **Reframe #164 D.3** to "test that the content intents carry the expected schema
   conformance" (no `register()` call exists to add).
3. Route the confirmation/diagnostics metadata ideas to **#239 / #236**, not a parallel
   MCP registry.
4. Next step if approved: a focused design for the `WordProcessor` adoption, starting from
   a per-intent diff of `AddPageIntent` / `PreviewSiteIntent` / `PageEntity` against the
   schema's required members.
