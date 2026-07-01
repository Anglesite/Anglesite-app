# Cross-cutting Decisions for the Pivot — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ratify three cross-cutting decisions (#340) that unblock the rest of the pivot epic (#334): adopt IndieWeb as the explicit content + protocol model (C.1), define the `@dwk/workers` integration seam with release tracking (C.2), and settle received-interaction data canonicality (C.3).

**Architecture:** C.1 is a documentation + validation task — V-1 already shipped the IndieWeb-aligned content model; this task records the decision, adds a conformance spec, and wires a build-time mf2 validation gate. C.2 adds the per-site Worker provisioning seam to `AnglesiteCore` (wrangler.toml generation, Worker composition template, CF API expansion, version pinning) and a conformance dashboard that reads `@dwk/workers`' `conformance/status.json`. C.3 is a design decision document + the `Interaction` schema that V-3 will later implement.

**Tech Stack:** Swift (AnglesiteCore), TypeScript (template Worker stub, conformance reader), Cloudflare Workers API v4, `@dwk/workers` composition model.

## Global Constraints

- macOS 27+ / Swift 6.4 / SwiftUI 27.
- No third-party Swift dependencies beyond Sparkle.
- All process spawning through `ProcessSupervisor`.
- `#if ANGLESITE_MAS` only on the app target, never in AnglesiteCore/AnglesiteBridge.
- Git is the source of truth (#72). Received interactions must snapshot into `Source/`.
- Template changes must pass `swift test --filter IntegrationTemplateAssetsTests`.
- All `@dwk/workers` integration is gated on conformance status (no stable release until micropub.rocks / webmention.rocks pass).

---

### Task 1: C.1 — Ratify IndieWeb as the Content + Protocol Model

This is the keystone decision: formally adopt IndieWeb (microformats2, Micropub, Webmention, IndieAuth) as the content vocabulary and federation protocol stack. V-1 already built the infrastructure; this task records the decision, adds a conformance reference, and ensures the shipped mf2/schema.org projections are gated in CI.

**Files:**
- Create: `docs/specs/2026-06-29-c1-indieweb-content-model-decision.md`
- Modify: `Resources/Template/scripts/check-microformats.ts` (verify coverage guards exist)

**Interfaces:**
- Consumes: `ContentTypeRegistry.builtIns` (Swift), `content.config.ts` (Zod schemas), `Hentry.astro`/`Hevent.astro`/`Hreview.astro` (mf2 templates), `schema.ts` (JSON-LD), existing `check-microformats.ts` build-time validator
- Produces: Decision document referenced by #340 and the pivot epic; no new code interfaces

- [ ] **Step 1: Write the C.1 decision document**

Create `docs/specs/2026-06-29-c1-indieweb-content-model-decision.md`:

```markdown
# C.1: Adopt IndieWeb as the Explicit Content + Protocol Model

**Date:** 2026-06-29
**Status:** Decided
**Part of:** #340 (cross-cutting decisions), #334 (pivot epic)
**Prerequisite for:** V-2 (social outbound), V-3 (social inbound), V-4 (federation)

---

## Decision

Anglesite adopts the **IndieWeb** content vocabulary and protocol stack as its
explicit content + protocol model. This is not a new direction — V-1 already
built the infrastructure — but a formal commitment that governs all future
content-type and federation work.

### What this means

1. **Content vocabulary = microformats2 post types.** Every content type in the
   `ContentTypeRegistry` maps to an mf2 root class (`h-entry`, `h-event`,
   `h-review`, `h-card`). The Zod schema in `content.config.ts` is the single
   source of truth; it projects three ways:
   - **Astro types** — editing + rendering (frontmatter → template)
   - **microformats2** — federation (h-entry classes in HTML)
   - **schema.org JSON-LD** — search (rich results)

2. **Protocol stack = IndieWeb + ActivityPub (via `@dwk/workers`).** The
   federation/interaction protocols are:
   - **Webmention** (send + receive) — the primary interaction primitive
   - **Micropub** (create/update/delete) — the posting API
   - **IndieAuth** (auth + identity) — the auth layer
   - **WebSub** (pub/sub notifications) — real-time subscriber notify
   - **ActivityPub** (federation) — Fediverse interop (V-4)
   - **Microsub** (reader) — feed consumption (V-4)

   All implemented by `@dwk/workers`, composed into a per-site Cloudflare Worker.
   Anglesite integrates, not builds.

3. **h-card as site identity.** The `personalProfile` / `businessProfile`
   singletons are the representative h-card, emitted in every page's footer.
   This is the identity Webmention, IndieAuth, and ActivityPub discover.

### What's already shipped (V-1)

| Layer | Status | Location |
|---|---|---|
| Content type registry (Swift) | ✅ Shipped | `Sources/AnglesiteCore/ContentTypeRegistry.swift` |
| Zod schemas (11 collections) | ✅ Shipped | `Resources/Template/src/content.config.ts` |
| mf2 templates (h-entry/h-event/h-review/h-card) | ✅ Shipped | `Resources/Template/src/layouts/` |
| schema.org JSON-LD | ✅ Shipped | `Resources/Template/src/lib/schema.ts` |
| RSS/Atom/JSON feeds | ✅ Shipped | `Resources/Template/src/pages/{rss,atom,feed}.*` |
| Per-type SwiftUI editors | ✅ Shipped | `Sources/AnglesiteApp/NewContentSheets.swift` |
| App-Intent entities | ✅ Shipped | `Sources/AnglesiteIntents/ContentEntities.swift` |
| Build-time mf2 validation | ✅ Shipped | `Resources/Template/scripts/check-microformats.ts` |

### What this decision enables

- **V-2:** Webmention send on publish. The mf2 markup is already the
  canonical source the sender parses to discover reply/like/bookmark targets.
- **V-3:** Micropub create/update/delete. The Zod schema is the contract
  between the Micropub endpoint and the content collection.
- **V-4:** ActivityPub. The h-card is the actor identity; h-entry posts
  federate as `Create`/`Update` activities.

### Design principles locked

- **One schema, three projections.** Every content type is defined once in Zod
  and projected to Astro types (editing), mf2 classes (federation), and
  schema.org JSON-LD (search). No duplication.
- **Static where possible, dynamic only for interaction.** Published content is
  static HTML with mf2 classes. The dynamic Worker handles *receiving*
  interactions (webmentions, micropub, inbox) — not *rendering* content.
- **No custom vocabulary.** We emit standard mf2 properties, not proprietary
  extensions. If a post type doesn't map cleanly to mf2, it's a signal we're
  inventing rather than adopting.
```

- [ ] **Step 2: Verify the mf2 build-time validator covers all collections**

Read `Resources/Template/scripts/check-microformats.ts` and confirm it validates every
collection in `content.config.ts`. The validator runs as part of `npm run build` (the
`build` script's post-build step). If any collection is missing from validation, add it.

Run: `cd Resources/Template && cat scripts/check-microformats.ts | grep -E "ENTRY_COLLECTIONS|collections|h-entry|h-event|h-review"`

Expected: every routed collection is covered — notes, articles, photos, albums, bookmarks,
replies, likes, announcements, events, reviews.

- [ ] **Step 3: Commit**

```bash
git add docs/specs/2026-06-29-c1-indieweb-content-model-decision.md
git commit -m "docs(#340): C.1 — ratify IndieWeb as the content + protocol model"
```

---

### Task 2: C.2 Part A — `@dwk/workers` Version Pinning + Conformance Dashboard

Track the `@dwk/workers` conformance status as a first-class app concern. Add a conformance
status reader that parses the monorepo's `conformance/status.json` and reports which packages
are release-ready. This gates V-2/V-3: the app will not enable social features until the
relevant packages pass their conformance suites.

**Files:**
- Create: `Sources/AnglesiteCore/WorkersConformance.swift`
- Create: `Tests/AnglesiteCoreTests/WorkersConformanceTests.swift`

**Interfaces:**
- Consumes: `conformance/status.json` from the `@dwk/workers` monorepo (pure JSON, read at dev time or bundled as a resource)
- Produces: `WorkersConformanceStatus` (value type), `WorkersConformanceReader` (parser), consumed by C.2 Part B's provisioning gate and by a future Settings > Advanced panel

- [ ] **Step 1: Write the failing test for conformance status parsing**

```swift
// Tests/AnglesiteCoreTests/WorkersConformanceTests.swift
import Testing
@testable import AnglesiteCore

@Suite("WorkersConformance")
struct WorkersConformanceTests {
    @Test("parses a minimal status.json with one passing and one pending package")
    func parsesMinimalStatus() throws {
        let json = """
        {
          "packages": {
            "@dwk/webmention": {
              "standard": "Webmention",
              "suites": {
                "webmention.rocks/sender": { "status": "passing" },
                "webmention.rocks/receiver": { "status": "pending" }
              },
              "integration": { "status": "passing", "cases": [] }
            },
            "@dwk/micropub": {
              "standard": "Micropub",
              "suites": {
                "micropub.rocks": { "status": "pending" }
              },
              "integration": { "status": "pending", "cases": [] }
            }
          }
        }
        """.data(using: .utf8)!

        let status = try WorkersConformanceReader.parse(json)
        #expect(status.packages.count == 2)

        let webmention = try #require(status.packages["@dwk/webmention"])
        #expect(webmention.standard == "Webmention")
        #expect(webmention.isIntegrationPassing)
        #expect(!webmention.areAllSuitesPassing)

        let micropub = try #require(status.packages["@dwk/micropub"])
        #expect(!micropub.isIntegrationPassing)
        #expect(!micropub.areAllSuitesPassing)
    }

    @Test("gateStatus reports which V-2 packages are ready")
    func gateStatus() throws {
        let json = """
        {
          "packages": {
            "@dwk/webmention": {
              "standard": "Webmention",
              "suites": {
                "webmention.rocks/sender": { "status": "passing" },
                "webmention.rocks/receiver": { "status": "passing" }
              },
              "integration": { "status": "passing", "cases": [] }
            },
            "@dwk/indieauth": {
              "standard": "IndieAuth",
              "suites": {},
              "integration": { "status": "passing", "cases": [] }
            },
            "@dwk/micropub": {
              "standard": "Micropub",
              "suites": { "micropub.rocks": { "status": "pending" } },
              "integration": { "status": "pending", "cases": [] }
            }
          }
        }
        """.data(using: .utf8)!

        let status = try WorkersConformanceReader.parse(json)
        let v2Gate = status.gateStatus(for: .v2)
        #expect(v2Gate.ready.contains("@dwk/webmention"))
        #expect(v2Gate.ready.contains("@dwk/indieauth"))
        #expect(v2Gate.blocked.contains("@dwk/micropub"))
        #expect(!v2Gate.isUnblocked)
    }

    @Test("empty suites dict counts as passing (no external suite to run)")
    func emptySuitesArePassing() throws {
        let json = """
        {
          "packages": {
            "@dwk/indieauth": {
              "standard": "IndieAuth",
              "suites": {},
              "integration": { "status": "passing", "cases": [] }
            }
          }
        }
        """.data(using: .utf8)!

        let status = try WorkersConformanceReader.parse(json)
        let indieauth = try #require(status.packages["@dwk/indieauth"])
        #expect(indieauth.areAllSuitesPassing)
        #expect(indieauth.isReleaseReady)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WorkersConformanceTests 2>&1 | tail -5`
Expected: FAIL — `WorkersConformanceReader` not found.

- [ ] **Step 3: Implement WorkersConformance**

```swift
// Sources/AnglesiteCore/WorkersConformance.swift
import Foundation

/// Parse result for one `@dwk/*` package from `conformance/status.json`.
public struct WorkersPackageStatus: Sendable, Equatable {
    public let name: String
    public let standard: String?
    public let suites: [String: SuiteStatus]
    public let integrationStatus: String

    public var isIntegrationPassing: Bool { integrationStatus == "passing" }
    public var areAllSuitesPassing: Bool {
        suites.isEmpty || suites.values.allSatisfy { $0.status == "passing" }
    }
    public var isReleaseReady: Bool { isIntegrationPassing && areAllSuitesPassing }
}

public struct SuiteStatus: Sendable, Equatable, Decodable {
    public let status: String
}

/// The full conformance snapshot.
public struct WorkersConformanceStatus: Sendable, Equatable {
    public let packages: [String: WorkersPackageStatus]

    /// Which phase a set of packages gates.
    public enum Phase {
        case v2  // webmention (send), indieauth
        case v3  // micropub, webmention (receive), websub
        case v4  // activitypub, microsub, webfinger
    }

    static let phaseRequirements: [Phase: [String]] = [
        .v2: ["@dwk/webmention", "@dwk/indieauth"],
        .v3: ["@dwk/micropub", "@dwk/webmention", "@dwk/websub"],
        .v4: ["@dwk/activitypub", "@dwk/microsub", "@dwk/webfinger"],
    ]

    public struct GateResult: Sendable, Equatable {
        public let phase: Phase
        public let ready: [String]
        public let blocked: [String]
        public var isUnblocked: Bool { blocked.isEmpty }
    }

    public func gateStatus(for phase: Phase) -> GateResult {
        let required = Self.phaseRequirements[phase] ?? []
        var ready: [String] = []
        var blocked: [String] = []
        for name in required {
            if let pkg = packages[name], pkg.isReleaseReady {
                ready.append(name)
            } else {
                blocked.append(name)
            }
        }
        return GateResult(phase: phase, ready: ready, blocked: blocked)
    }
}

public enum WorkersConformanceReader {
    public static func parse(_ data: Data) throws -> WorkersConformanceStatus {
        struct Root: Decodable {
            let packages: [String: PackageEntry]
        }
        struct PackageEntry: Decodable {
            let standard: String?
            let suites: [String: SuiteStatus]?
            let integration: IntegrationEntry?
        }
        struct IntegrationEntry: Decodable {
            let status: String
        }

        let root = try JSONDecoder().decode(Root.self, from: data)
        var packages: [String: WorkersPackageStatus] = [:]
        for (name, entry) in root.packages {
            packages[name] = WorkersPackageStatus(
                name: name,
                standard: entry.standard,
                suites: entry.suites ?? [:],
                integrationStatus: entry.integration?.status ?? "pending"
            )
        }
        return WorkersConformanceStatus(packages: packages)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WorkersConformanceTests 2>&1 | tail -5`
Expected: All 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WorkersConformance.swift Tests/AnglesiteCoreTests/WorkersConformanceTests.swift
git commit -m "feat(#340): C.2a — @dwk/workers conformance status parser + phase gate"
```

---

### Task 3: C.2 Part B — Per-Site Worker Composition Template

Stand up the "provision + deploy a per-site Worker" seam. Today `DeployCommand` runs `wrangler deploy` for static assets only. The social layer needs a **composed Worker** — a `wrangler.toml` + entry-point script that mounts `@dwk/indieauth`, `@dwk/micropub`, `@dwk/webmention`, etc. under path prefixes behind the site's static assets.

This task creates the Worker composition template (a `wrangler.toml` and `worker.ts` that the scaffold can drop into `Source/`) and the Swift-side `WorkerComposition` type that generates them. The actual provisioning (creating D1 databases, R2 buckets via the CF API) is a V-2.1 task (#353); this task builds the seam and the template.

**Files:**
- Create: `Sources/AnglesiteCore/WorkerComposition.swift`
- Create: `Tests/AnglesiteCoreTests/WorkerCompositionTests.swift`
- Create: `Resources/Template/worker/worker.ts` (stub entry point)
- Create: `Resources/Template/worker/wrangler.toml.template` (template for wrangler config)

**Interfaces:**
- Consumes: `WorkersConformanceStatus` (from Task 2), site domain (from deploy flow)
- Produces: `WorkerComposition.generateWranglerToml(site:features:) -> String`, `WorkerComposition.Feature` enum. Consumed by V-2.1 (#353) provisioning flow and future `DeployCommand` expansion.

- [ ] **Step 1: Write the failing test for WorkerComposition**

```swift
// Tests/AnglesiteCoreTests/WorkerCompositionTests.swift
import Testing
@testable import AnglesiteCore

@Suite("WorkerComposition")
struct WorkerCompositionTests {
    @Test("generates wrangler.toml with static assets and no social features")
    func staticOnly() {
        let toml = WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            features: []
        )
        #expect(toml.contains("name = \"my-site\""))
        #expect(toml.contains("[assets]"))
        #expect(toml.contains("directory = \"dist\""))
        #expect(!toml.contains("[[d1_databases]]"))
    }

    @Test("generates wrangler.toml with webmention + indieauth features")
    func withSocialFeatures() {
        let toml = WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            features: [.webmention, .indieauth]
        )
        #expect(toml.contains("name = \"my-site\""))
        #expect(toml.contains("[assets]"))
        #expect(toml.contains("[[d1_databases]]"))
        #expect(toml.contains("binding = \"DB\""))
        #expect(toml.contains("[[r2_buckets]]"))
        #expect(toml.contains("binding = \"MEDIA\""))
    }

    @Test("generates wrangler.toml with all V-2 features")
    func v2Features() {
        let toml = WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            features: WorkerComposition.Feature.v2
        )
        #expect(toml.contains("[[d1_databases]]"))
        #expect(toml.contains("[[r2_buckets]]"))
    }

    @Test("feature sets are correctly defined per phase")
    func featureSets() {
        #expect(WorkerComposition.Feature.v2.contains(.webmention))
        #expect(WorkerComposition.Feature.v2.contains(.indieauth))
        #expect(!WorkerComposition.Feature.v2.contains(.micropub))

        #expect(WorkerComposition.Feature.v3.contains(.micropub))
        #expect(WorkerComposition.Feature.v3.contains(.websub))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WorkerCompositionTests 2>&1 | tail -5`
Expected: FAIL — `WorkerComposition` not found.

- [ ] **Step 3: Implement WorkerComposition**

```swift
// Sources/AnglesiteCore/WorkerComposition.swift
import Foundation

/// Generates the wrangler.toml and entry-point configuration for a per-site Cloudflare Worker
/// that composes `@dwk/*` social endpoints behind the site's static assets.
///
/// Today's deploy is static-only (`wrangler deploy` with `[assets]`). The social layer (V-2+)
/// adds a Worker script that mounts `@dwk/indieauth`, `@dwk/webmention`, etc. under path
/// prefixes. This type generates the configuration; actual CF resource provisioning (D1/R2
/// creation) is a V-2.1 task (#353).
public enum WorkerComposition {
    /// A social feature that can be composed into the per-site Worker.
    public enum Feature: String, CaseIterable, Sendable {
        case indieauth
        case webmention
        case micropub
        case websub
        case microsub
        case webfinger
        case activitypub

        /// V-2 features: outbound social (webmention send + indieauth).
        public static let v2: [Feature] = [.webmention, .indieauth]
        /// V-3 features: V-2 + inbound social (micropub + websub).
        public static let v3: [Feature] = [.webmention, .indieauth, .micropub, .websub]
        /// V-4 features: V-3 + federation (activitypub + microsub + webfinger).
        public static let v4: [Feature] = Feature.allCases.map { $0 }

        var needsD1: Bool {
            switch self {
            case .webmention, .micropub, .indieauth, .websub, .microsub, .activitypub:
                return true
            case .webfinger:
                return false
            }
        }

        var needsR2: Bool {
            switch self {
            case .micropub:
                return true
            default:
                return false
            }
        }
    }

    /// Generates a wrangler.toml for a site with the given features enabled.
    ///
    /// - Parameters:
    ///   - siteName: The Worker name (used as the Cloudflare Workers project name).
    ///   - features: Which `@dwk/*` social endpoints to compose. Empty = static-only deploy.
    /// - Returns: A complete wrangler.toml string.
    public static func generateWranglerToml(
        siteName: String,
        features: [Feature]
    ) -> String {
        var lines: [String] = []
        lines.append("name = \"\(siteName)\"")
        lines.append("compatibility_date = \"2025-01-01\"")

        let hasSocialFeatures = !features.isEmpty
        if hasSocialFeatures {
            lines.append("main = \"worker/worker.ts\"")
        }
        lines.append("")
        lines.append("[assets]")
        lines.append("directory = \"dist\"")

        if features.contains(where: { $0.needsD1 }) {
            lines.append("")
            lines.append("[[d1_databases]]")
            lines.append("binding = \"DB\"")
            lines.append("database_name = \"\(siteName)-social\"")
            lines.append("database_id = \"\"  # filled by provisioning")
        }

        if features.contains(where: { $0.needsR2 }) {
            lines.append("")
            lines.append("[[r2_buckets]]")
            lines.append("binding = \"MEDIA\"")
            lines.append("bucket_name = \"\(siteName)-media\"")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WorkerCompositionTests 2>&1 | tail -5`
Expected: All 4 tests PASS.

- [ ] **Step 5: Create the Worker entry-point stub**

Create `Resources/Template/worker/worker.ts`:

```typescript
/**
 * Per-site Cloudflare Worker entry point.
 *
 * Composes @dwk/* social endpoints behind the site's static assets. This file is
 * generated/managed by Anglesite — manual edits are preserved between scaffolds but
 * the composition block is regenerated when features change.
 *
 * Static assets are served by the [assets] binding in wrangler.toml; this Worker
 * handles only the social endpoint paths. When no social features are enabled, this
 * file is not referenced (wrangler.toml has no `main` entry and deploys static-only).
 */

// Placeholder — V-2.1 (#353) will wire the actual @dwk/* imports here.
// The composition pattern follows @dwk/workers' documented model:
//
//   import { createIndieAuth } from "@dwk/indieauth";
//   import { createWebmention } from "@dwk/webmention";
//
//   const indieauth = createIndieAuth({ baseUrl });
//   const webmention = createWebmention({ baseUrl });
//
//   export default {
//     async fetch(request, env, ctx) {
//       const url = new URL(request.url);
//       if (url.pathname.startsWith("/.well-known/indieauth"))
//         return indieauth.fetch(request, env, ctx);
//       if (url.pathname.startsWith("/webmention"))
//         return webmention.fetch(request, env, ctx);
//       return env.ASSETS.fetch(request);
//     }
//   };

export default {
  async fetch(request: Request, env: Record<string, unknown>): Promise<Response> {
    // No social features enabled yet — fall through to static assets.
    // The ASSETS binding is provided by wrangler's [assets] config.
    const assets = env.ASSETS as { fetch: typeof fetch };
    return assets.fetch(request);
  },
};
```

- [ ] **Step 6: Create the wrangler.toml template**

Create `Resources/Template/worker/wrangler.toml.template`:

```toml
# Per-site Worker configuration — managed by Anglesite.
# Static-only sites omit the `main` entry and deploy dist/ directly.
# Social features (V-2+) set `main = "worker/worker.ts"` and add bindings below.
#
# Do not edit the [[d1_databases]] / [[r2_buckets]] blocks manually — Anglesite's
# provisioning flow (#353) fills the database_id and bucket_name from the CF API.

name = "{{SITE_NAME}}"
compatibility_date = "2025-01-01"
# main = "worker/worker.ts"  # uncommented when social features are enabled

[assets]
directory = "dist"

# Social features add these bindings (uncommented by Anglesite when enabled):
# [[d1_databases]]
# binding = "DB"
# database_name = "{{SITE_NAME}}-social"
# database_id = ""
#
# [[r2_buckets]]
# binding = "MEDIA"
# bucket_name = "{{SITE_NAME}}-media"
```

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/WorkerComposition.swift \
        Tests/AnglesiteCoreTests/WorkerCompositionTests.swift \
        Resources/Template/worker/worker.ts \
        Resources/Template/worker/wrangler.toml.template
git commit -m "feat(#340): C.2b — per-site Worker composition template + wrangler.toml generator"
```

---

### Task 4: C.2 Part C — Integration Seam Design Document + Version Pinning

Write the design document that ties C.2 together: how `@dwk/workers` integrates with Anglesite, what version pinning means, how conformance gates releases, and the provisioning sequence V-2.1 will implement. Also add a version-pinning file that tracks the expected `@dwk/workers` version.

**Files:**
- Create: `docs/specs/2026-06-29-c2-workers-integration-seam.md`
- Create: `Resources/Template/worker/workers-version.json`

**Interfaces:**
- Consumes: `WorkersConformanceStatus` (Task 2), `WorkerComposition` (Task 3), `@dwk/workers` README/conformance docs
- Produces: Decision document + version pin file; consumed by V-2.1 (#353) provisioning implementation

- [ ] **Step 1: Write the C.2 design document**

Create `docs/specs/2026-06-29-c2-workers-integration-seam.md`:

```markdown
# C.2: `@dwk/workers` Integration Seam + Release Tracking

**Date:** 2026-06-29
**Status:** Decided
**Part of:** #340 (cross-cutting decisions), #334 (pivot epic)
**Prerequisite for:** V-2.1 (#353, per-site Worker provisioning)

---

## Decision

Anglesite integrates `@dwk/workers` as its social/protocol backend by **composing
`@dwk/*` packages into a per-site Cloudflare Worker** deployed alongside the
static site. The integration is version-pinned and conformance-gated.

### Integration model

```
┌─────────────────────────────────────────────────┐
│ Per-site Cloudflare Worker                       │
│                                                  │
│   worker.ts (entry point)                        │
│     ├── @dwk/indieauth  → /.well-known/indieauth│
│     ├── @dwk/webmention → /webmention            │
│     ├── @dwk/micropub   → /micropub              │
│     ├── @dwk/websub     → /.well-known/websub    │
│     └── env.ASSETS      → /* (static fallback)   │
│                                                  │
│   Bindings:                                      │
│     D1 "DB"    — social data (mentions, tokens)  │
│     R2 "MEDIA" — uploaded media (micropub)       │
│     KV "CACHE" — transient caches (optional)     │
└─────────────────────────────────────────────────┘
```

Each `@dwk/*` package exports a `createXxx({ baseUrl, ... })` factory returning a
`fetch`-compatible handler. The Worker entry point routes by path prefix, falling
through to static assets for everything else.

### Version pinning

`Resources/Template/worker/workers-version.json` declares the expected `@dwk/workers`
version range. The app reads this to:
- Install the correct versions during scaffold (`npm install @dwk/webmention@^x.y`)
- Warn if a site's installed versions are outdated
- Gate social feature enablement on minimum versions

### Conformance gating

Social features are phased and each phase is gated on `@dwk/workers` conformance:

| Phase | Required packages | Conformance bar |
|---|---|---|
| V-2 | `@dwk/webmention`, `@dwk/indieauth` | Integration passing + all suites passing |
| V-3 | + `@dwk/micropub`, `@dwk/websub` | Same |
| V-4 | + `@dwk/activitypub`, `@dwk/microsub`, `@dwk/webfinger` | Same |

`WorkersConformanceReader` (in `AnglesiteCore`) parses the monorepo's
`conformance/status.json` and `WorkersConformanceStatus.gateStatus(for:)` reports
readiness. Until a phase's packages are all release-ready, the app does not offer
that phase's features in the UI.

### Provisioning sequence (V-2.1 — #353)

When the user enables social features for a site:
1. App reads the Cloudflare API token (existing `DeployCommand.keychainTokenSource`)
2. App resolves the site's zone (existing `CloudflareReading.resolveZoneID`)
3. App creates the D1 database (`{siteName}-social`) via CF API → new `CloudflareWriting.createD1Database`
4. App creates the R2 bucket (`{siteName}-media`) if micropub is enabled → new `CloudflareWriting.createR2Bucket`
5. App writes `wrangler.toml` with filled binding IDs → `WorkerComposition.generateWranglerToml`
6. App scaffolds `worker/worker.ts` with the enabled imports
7. `npm install` the pinned `@dwk/*` packages
8. Deploy via `wrangler deploy` (existing `DeployCommand`)

Steps 3–7 are the new work in V-2.1. Steps 1–2 and 8 use existing infrastructure.

### What this task ships

- `WorkersConformanceReader` + `WorkersConformanceStatus` (Swift, AnglesiteCore)
- `WorkerComposition` (Swift, wrangler.toml generator)
- `worker/worker.ts` stub (template resource)
- `worker/wrangler.toml.template` (reference)
- `worker/workers-version.json` (version pin)
- This decision document
```

- [ ] **Step 2: Create the version pin file**

Create `Resources/Template/worker/workers-version.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "description": "Pinned @dwk/workers version range for this template. Read by Anglesite during scaffold and social-feature enablement. Updated when a new @dwk/workers release ships.",
  "version": "0.0.0",
  "range": "^0.0.0",
  "note": "@dwk/workers is pre-release (0.0.0). Social features (V-2+) are gated on conformance; this pin tracks the monorepo version the template was tested against.",
  "packages": {
    "@dwk/indieauth": "^0.0.0",
    "@dwk/webmention": "^0.0.0",
    "@dwk/micropub": "^0.0.0",
    "@dwk/websub": "^0.0.0",
    "@dwk/microsub": "^0.0.0",
    "@dwk/webfinger": "^0.0.0",
    "@dwk/activitypub": "^0.0.0"
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add docs/specs/2026-06-29-c2-workers-integration-seam.md \
        Resources/Template/worker/workers-version.json
git commit -m "docs(#340): C.2c — @dwk/workers integration seam design + version pin"
```

---

### Task 5: C.3 — Received-Interaction Data Canonicality Decision

Settle the data-canonicality question: when the Worker's inbox store receives a webmention, reply, like, or ActivityPub interaction, how does it flow back into `Source/` git so #72 holds? This is a design decision, not implementation — V-3.4 (#362) will build it.

**Files:**
- Create: `docs/specs/2026-06-29-c3-received-interaction-canonicality.md`
- Create: `Sources/AnglesiteCore/ReceivedInteraction.swift` (schema only — no I/O)
- Create: `Tests/AnglesiteCoreTests/ReceivedInteractionTests.swift`

**Interfaces:**
- Consumes: `@dwk/webmention` inbox store format, `@dwk/activitypub` inbox format, #72 invariant
- Produces: `ReceivedInteraction` value type (the schema V-3 stores in `Source/`), consumed by V-3.4 (#362) renderer and the git-snapshot pipeline

- [ ] **Step 1: Write the C.3 decision document**

Create `docs/specs/2026-06-29-c3-received-interaction-canonicality.md`:

```markdown
# C.3: Received-Interaction Data Canonicality

**Date:** 2026-06-29
**Status:** Decided
**Part of:** #340 (cross-cutting decisions), #334 (pivot epic)
**Prerequisite for:** V-3.4 (#362, render + snapshot received interactions)

---

## The Question

When someone else's site sends a webmention to your site (a reply, a like, a
repost), or when an ActivityPub actor delivers an activity to your inbox, the
Worker's inbox store (D1) records it. That data is **someone else's content,
cached on your infrastructure.** Is it canonical in your git repo (`Source/`)?

This matters because #72 says "git is the source of truth." If received
interactions only live in D1, they're lost when you move hosting providers — your
site's comment section evaporates. If they're in git, they survive any backend
migration.

## Decision

**Snapshot received interactions into `Source/` git.** The Worker periodically
(or on-demand) serializes verified interactions to JSON files in
`Source/data/interactions/`, committed to the site's repo. This is the
IndieWeb-standard approach: your site's git repo contains a complete, portable
record of both your content and the interactions it received.

### The schema

Each interaction is a JSON file at `Source/data/interactions/{id}.json`:

```json
{
  "id": "wm-abc123",
  "type": "webmention",
  "source": "https://other.example/post/42",
  "target": "https://my.site/articles/hello-world",
  "interactionType": "reply",
  "author": {
    "name": "Jane Doe",
    "url": "https://other.example",
    "photo": "https://other.example/photo.jpg"
  },
  "content": "Great post! I especially liked the part about...",
  "published": "2026-06-28T14:30:00Z",
  "verified": "2026-06-28T14:35:12Z",
  "verificationStatus": "verified"
}
```

Fields:
- `id`: Stable, unique ID assigned by the Worker (e.g. `wm-{hash}`, `ap-{hash}`)
- `type`: Protocol source — `"webmention"`, `"activitypub"`, `"micropub"`
- `source`: The URL that sent the interaction
- `target`: The URL on this site that received it
- `interactionType`: `"reply"`, `"like"`, `"repost"`, `"bookmark"`, `"mention"`
- `author`: Parsed h-card / ActivityPub actor (name, url, photo — all optional)
- `content`: Text/HTML content of the interaction (optional, may be truncated)
- `published`: When the source published it (ISO 8601)
- `verified`: When the Worker verified it (ISO 8601)
- `verificationStatus`: `"verified"`, `"pending"`, `"failed"`

### The flow

```
External site → Webmention/AP → Worker inbox (D1)
                                      │
                                      ▼
                              Verify (async queue)
                                      │
                                      ▼
                              Snapshot to git ─────────► Source/data/interactions/
                              (on verify, or periodic)     │
                                                           ▼
                                                    Astro build reads
                                                    interactions → renders
                                                    on the target page
```

### Design principles

1. **Git-canonical, D1-operational.** D1 is the live operational store (fast
   lookup, queue management). Git is the canonical archive. They stay in sync
   via a snapshot step — D1 → JSON → git commit → push. If they diverge, git
   wins (the snapshot is idempotent and overwritable).

2. **One file per interaction.** Not a monolithic `interactions.json`. This
   keeps git diffs clean (one new file per new interaction), avoids merge
   conflicts, and lets Astro's glob loader enumerate them efficiently.

3. **Verified only.** Only interactions that pass Webmention verification or
   ActivityPub signature validation are snapshotted to git. Pending/failed
   interactions stay in D1 for retry but do not enter the repo.

4. **Content is truncated.** The snapshot stores a summary of the interaction
   content (first ~500 chars), not the full remote page. This keeps the repo
   lean, avoids storing other people's full posts, and is sufficient for
   rendering a comment thread.

5. **Author data is a snapshot.** The `author` object is a frozen point-in-time
   copy of the sender's h-card / AP actor at verification time. It is not
   live-updated — if the sender changes their name/photo, the old values persist
   in the snapshot. This is standard IndieWeb practice.

### How the snapshot enters git

The Worker's snapshot step (V-3.4, #362):
1. Queries D1 for interactions verified since the last snapshot timestamp
2. Serializes each to `Source/data/interactions/{id}.json`
3. Commits: `chore: snapshot {n} received interactions`
4. Pushes to the site's repo

The app can trigger this on-demand (from the UI or via an App Intent), or the
Worker can run it on a cron schedule. The commit is a normal git commit — the
user can inspect, revert, or cherry-pick interaction snapshots like any other
content change.

### What about deletion?

If a sender deletes their webmention (sends a 410/404 on re-verification), the
Worker marks the interaction as deleted in D1, and the next snapshot removes the
file from git. This is a normal file deletion + commit.

If the site *owner* wants to hide an interaction (moderation), they delete the
JSON file from their repo. The Worker's D1 record is unaffected (it's operational
data), but the interaction no longer renders on the static site. A future
moderation UI (V-5.3, #370) could add a `moderation` field to the schema instead
of file deletion.

### Astro consumption

`Source/data/interactions/` is loaded by Astro's glob loader at build time.
The page template for each content entry queries interactions where
`target` matches the entry's canonical URL, groups by `interactionType`, and
renders them (replies as a comment thread, likes/reposts as facepile counts).

This is static — the interaction display updates on next build, not in real time.
Real-time display is a future enhancement (WebSocket from the Worker to the
page, or a client-side fetch to the Worker's API).
```

- [ ] **Step 2: Write the failing test for ReceivedInteraction**

```swift
// Tests/AnglesiteCoreTests/ReceivedInteractionTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ReceivedInteraction")
struct ReceivedInteractionTests {
    @Test("round-trips through JSON encoding")
    func jsonRoundTrip() throws {
        let interaction = ReceivedInteraction(
            id: "wm-abc123",
            type: .webmention,
            source: URL(string: "https://other.example/post/42")!,
            target: URL(string: "https://my.site/articles/hello-world")!,
            interactionType: .reply,
            author: ReceivedInteraction.Author(
                name: "Jane Doe",
                url: URL(string: "https://other.example"),
                photo: URL(string: "https://other.example/photo.jpg")
            ),
            content: "Great post!",
            published: ISO8601DateFormatter().date(from: "2026-06-28T14:30:00Z")!,
            verified: ISO8601DateFormatter().date(from: "2026-06-28T14:35:12Z")!,
            verificationStatus: .verified
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(interaction)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ReceivedInteraction.self, from: data)
        #expect(decoded == interaction)
    }

    @Test("interaction type maps to expected display categories")
    func interactionTypeCategories() {
        #expect(ReceivedInteraction.InteractionType.reply.isComment)
        #expect(ReceivedInteraction.InteractionType.like.isFacepile)
        #expect(ReceivedInteraction.InteractionType.repost.isFacepile)
        #expect(!ReceivedInteraction.InteractionType.mention.isComment)
        #expect(!ReceivedInteraction.InteractionType.mention.isFacepile)
    }

    @Test("gitPath produces the expected file path")
    func gitPath() {
        let interaction = ReceivedInteraction(
            id: "wm-abc123",
            type: .webmention,
            source: URL(string: "https://example.com")!,
            target: URL(string: "https://my.site/post")!,
            interactionType: .mention,
            author: nil,
            content: nil,
            published: Date(),
            verified: Date(),
            verificationStatus: .verified
        )
        #expect(interaction.gitPath == "data/interactions/wm-abc123.json")
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter ReceivedInteractionTests 2>&1 | tail -5`
Expected: FAIL — `ReceivedInteraction` not found.

- [ ] **Step 4: Implement ReceivedInteraction**

```swift
// Sources/AnglesiteCore/ReceivedInteraction.swift
import Foundation

/// Schema for a received interaction snapshotted from the Worker's inbox store into `Source/` git.
///
/// This is the data contract between the Worker (D1 → JSON serialization) and the Astro template
/// (glob loader → render). One file per interaction at `Source/data/interactions/{id}.json`.
/// See `docs/specs/2026-06-29-c3-received-interaction-canonicality.md` for the full design.
public struct ReceivedInteraction: Codable, Sendable, Equatable, Identifiable {
    /// Protocol source of the interaction.
    public enum ProtocolType: String, Codable, Sendable, Equatable {
        case webmention
        case activitypub
        case micropub
    }

    /// What kind of interaction this represents.
    public enum InteractionType: String, Codable, Sendable, Equatable {
        case reply
        case like
        case repost
        case bookmark
        case mention

        /// Whether this interaction renders as a threaded comment.
        public var isComment: Bool { self == .reply }
        /// Whether this interaction renders as a facepile avatar.
        public var isFacepile: Bool { self == .like || self == .repost }
    }

    /// Verification state of the interaction.
    public enum VerificationStatus: String, Codable, Sendable, Equatable {
        case verified
        case pending
        case failed
    }

    /// Frozen point-in-time snapshot of the sender's identity.
    public struct Author: Codable, Sendable, Equatable {
        public let name: String?
        public let url: URL?
        public let photo: URL?

        public init(name: String?, url: URL?, photo: URL?) {
            self.name = name
            self.url = url
            self.photo = photo
        }
    }

    public let id: String
    public let type: ProtocolType
    public let source: URL
    public let target: URL
    public let interactionType: InteractionType
    public let author: Author?
    public let content: String?
    public let published: Date
    public let verified: Date
    public let verificationStatus: VerificationStatus

    /// The relative path within `Source/` where this interaction is stored.
    public var gitPath: String { "data/interactions/\(id).json" }

    public init(
        id: String,
        type: ProtocolType,
        source: URL,
        target: URL,
        interactionType: InteractionType,
        author: Author?,
        content: String?,
        published: Date,
        verified: Date,
        verificationStatus: VerificationStatus
    ) {
        self.id = id
        self.type = type
        self.source = source
        self.target = target
        self.interactionType = interactionType
        self.author = author
        self.content = content
        self.published = published
        self.verified = verified
        self.verificationStatus = verificationStatus
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ReceivedInteractionTests 2>&1 | tail -5`
Expected: All 3 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add docs/specs/2026-06-29-c3-received-interaction-canonicality.md \
        Sources/AnglesiteCore/ReceivedInteraction.swift \
        Tests/AnglesiteCoreTests/ReceivedInteractionTests.swift
git commit -m "feat(#340): C.3 — received-interaction canonicality decision + schema"
```

---

### Task 6: Close Issue + Update Tracking

Update the #340 issue with references to the shipped decisions and close it.

**Files:**
- Modify: (GitHub issue only — no file changes)

**Interfaces:**
- Consumes: All prior tasks' commits
- Produces: Closed #340 with all three checkboxes checked

- [ ] **Step 1: Verify all tests pass**

Run: `swift test --filter "WorkersConformance|WorkerComposition|ReceivedInteraction" 2>&1 | tail -10`
Expected: All tests PASS (10 tests across 3 suites).

- [ ] **Step 2: Verify the app still links**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

(If `Anglesite.xcodeproj` doesn't exist in the worktree, run `xcodegen generate` first.)

- [ ] **Step 3: Open PR**

```bash
git push -u origin HEAD
gh pr create \
  --title "feat(#340): cross-cutting decisions for the pivot (C.1 + C.2 + C.3)" \
  --body "$(cat <<'EOF'
## Summary

Resolves #340. Three cross-cutting decisions that unblock the rest of the pivot epic (#334):

- **C.1: Adopt IndieWeb as the content + protocol model** — decision document ratifying what V-1 already built (mf2 post types, one-schema-three-projections, `@dwk/workers` as protocol backend)
- **C.2: `@dwk/workers` integration seam + release tracking** — conformance status parser (`WorkersConformanceReader`), phase gating (`WorkersConformanceStatus.gateStatus`), Worker composition template (`WorkerComposition`), wrangler.toml generator, version pin file
- **C.3: Received-interaction data canonicality** — decision document + `ReceivedInteraction` schema (one JSON file per interaction in `Source/data/interactions/`, git-canonical, verified-only)

## What's new in code

| Type | File |
|---|---|
| Swift | `WorkersConformance.swift` — parse `@dwk/workers` conformance/status.json, gate by phase |
| Swift | `WorkerComposition.swift` — generate wrangler.toml for static-only or social Worker deploys |
| Swift | `ReceivedInteraction.swift` — Codable schema for git-snapshotted interactions |
| Template | `worker/worker.ts` — stub entry point for the composed Worker |
| Template | `worker/wrangler.toml.template` — reference wrangler config |
| Template | `worker/workers-version.json` — version pin for @dwk/* packages |
| Docs | C.1, C.2, C.3 decision documents |
| Tests | 10 new tests across 3 suites |

## Test plan

- [ ] `swift test --filter WorkersConformanceTests` — conformance parsing + phase gating
- [ ] `swift test --filter WorkerCompositionTests` — wrangler.toml generation
- [ ] `swift test --filter ReceivedInteractionTests` — interaction schema round-trip
- [ ] `xcodebuild -scheme Anglesite build` — app still links

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: Close the issue via the PR**

The PR body references `Resolves #340`; GitHub will close it on merge. Verify the three checkboxes on #340 are referenced in the PR.
