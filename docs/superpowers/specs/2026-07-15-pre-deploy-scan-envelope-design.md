# Pre-deploy scan JSON envelope — design (#742)

- **Date:** 2026-07-15
- **Status:** Proposed
- **Issue:** [#742 — Pre-deploy scan: version and unify the JSON contract](https://github.com/Anglesite/Anglesite-app/issues/742)
- **Related:** first step of the V-2 IndieAuth chain ([#355](https://github.com/Anglesite/Anglesite-app/issues/355) via #746/#744/#708/#709/#748/#743); blocks [#743](https://github.com/Anglesite/Anglesite-app/issues/743) and [#744](https://github.com/Anglesite/Anglesite-app/issues/744)

## Problem

`Resources/Template/scripts/pre-deploy-check.ts --json` emits a flat `Issue[]` array:
`{ severity: "error" | "warning", message: string, file?: string }`.

Both Swift consumers instead decode `{ ok: Bool, failures: [ScanFailure], warnings: [ScanWarning] }`,
where `ScanFailure`/`ScanWarning` require a closed-enum `category` plus non-optional `detail` and
`remediation` fields the script never emits:

- `Sources/AnglesiteCore/PreDeployCheck.swift`'s `check(siteID:siteDirectory:)` — declares its own
  inline `RawReport` struct. **Dead code**: nothing in `Sources/` calls it.
- `Sources/AnglesiteCore/DeployCommand.swift`'s `parseScanReport(output:exitCode:)` — the live path,
  invoked from `DeployCommand.deploy` via `DeployExecutor`.

Because the real script's output is a top-level JSON *array* and the decoder expects an *object*,
`JSONDecoder` throws on every real invocation, and `parseScanReport` maps that straight to
`.error("pre-deploy scan emitted no JSON...")` — **every real deploy's pre-deploy scan currently
fails to decode**, regardless of whether the site actually has any PII/secret/tracking-script
issues. This has gone uncaught because every existing test (`PreDeployCheckTests`,
`DeployCommandTests`, `DeployModelTests`, `HealthModelTests`, `SiteOperationsTests`,
`DeploySiteIntentTests`) hand-authors JSON fixtures in the *Swift-expected* shape — none run the
actual TypeScript script and feed its real stdout through the decoder.

The category taxonomies are also out of sync with reality:

- `ScanFailure.Category` has `piiEmail`, `piiPhone`, `exposedToken`, `thirdPartyScript`,
  `keystaticRoute` — but the script's `checkPII` also matches SSNs (no category), and
  `checkHeaders`'s three `error`-severity findings (missing `_headers`, missing CSP directive,
  missing configured domain) have no category at all.
- `ScanWarning.Category` has `missingOgImage`, `maintenanceOverdue`, `seoCritical`, `seoWarning`,
  `orphanedRoute` — but **none of the first four are ever constructed anywhere in `Sources/`**
  (dead, forward-declared cases). Only `orphanedRoute` is real, computed by `RouteCoverageScanner`
  and merged into the `Outcome` by `DeployCommand.deploy` — it never comes from the script's JSON
  at all. Meanwhile the script's real `warning`-severity findings (`checkMixedContent`, `checkSRI`
  ×2, `checkExternalLinkRel`, `checkArtifactPresence`, and `BLOCKED_SCRIPTS`'s third-party-script
  detection, which today is scored a *warning*, not an error) have no matching category.

## Decision

Define one versioned JSON envelope, shared by TypeScript and Swift, replace the two divergent
Swift decoders with one, and add a real producer→consumer fixture test.

### Envelope shape

```ts
// Resources/Template/scripts/pre-deploy-check.ts
interface ScanFinding {
  severity: "error" | "warning";
  category: string;        // stable kebab-case code; see taxonomy below
  message: string;         // required — today's Issue.message
  file?: string;
  detail?: string;         // optional richer elaboration; script may omit
  remediation?: string;    // optional "how to fix"; script may omit
}
interface ScanReport {
  version: 1;
  ok: boolean;             // true iff failures is empty
  failures: ScanFinding[]; // severity: "error"
  warnings: ScanFinding[]; // severity: "warning"
}
```

```swift
// Sources/AnglesiteCore/PreDeployCheck.swift
public struct ScanFailure: Sendable, Equatable, Codable {
    public enum Category: String, Sendable, Codable, CaseIterable {
        case piiEmail = "pii-email"
        case piiPhone = "pii-phone"
        case piiSSN = "pii-ssn"
        case exposedToken = "exposed-token"
        case thirdPartyScript = "third-party-script"   // unused by the script (see below); kept for compatibility
        case keystaticRoute = "keystatic-route"
        case cspMisconfigured = "csp-misconfigured"
        case other
    }
    public let category: Category
    public let message: String
    public let file: String?
    public let detail: String?
    public let remediation: String?
}

public struct ScanWarning: Sendable, Equatable, Codable {
    public enum Category: String, Sendable, Codable, CaseIterable {
        case missingOgImage = "missing-og-image"       // unused today; kept, no producer yet
        case maintenanceOverdue = "maintenance-overdue" // unused today; kept, no producer yet
        case seoCritical = "seo-critical"               // unused today; kept, no producer yet
        case seoWarning = "seo-warning"                 // unused today; kept, no producer yet
        case orphanedRoute = "orphaned-route"           // RouteCoverageScanner, merged separately
        case mixedContent = "mixed-content"
        case sriMissing = "sri-missing"
        case externalLinkRel = "external-link-rel"
        case missingSecurityArtifact = "missing-security-artifact"
        case thirdPartyScript = "third-party-script"    // script currently scores this a warning
        case other
    }
    public let category: Category
    public let message: String
    public let file: String?
    public let detail: String?
    public let remediation: String?
}
```

`Category` decodes any unrecognized raw value to `.other` rather than throwing — a custom
`init(from:)` catches the enum-decode failure and falls back, so a future/typo'd category code
never crashes the whole scan result. `.other` renders with a generic icon/label in the UI (see
below) instead of extending the exhaustive switch.

Severities are **not** being reclassified in this change — `third-party-script` stays a warning,
matching the script's current behavior, per the issue's "preserving current exit-code semantics."
Re-scoring it to an error is a separate product decision, out of scope here.

### One shared decoder

`DeployCommand.parseScanReport(output:exitCode:)` becomes the single implementation.
`PreDeployCheck.check` calls it instead of re-declaring its own `RawReport`; its inline struct is
deleted.

### Legacy fallback

Existing scaffolded sites keep their already-checked-in `pre-deploy-check.ts` until template
Dependency Sync updates it — until then, they still emit the bare `Issue[]` with no envelope. The
shared decoder:

1. Tries decoding `ScanReport` (the new envelope). On success, use it directly.
2. On failure, tries decoding `[Issue]` where `Issue = { severity, message, file? }` (today's
   shape). On success, splits by `severity` into `failures`/`warnings`, synthesizes
   `category: .other` and `detail: nil, remediation: nil` for each, and computes
   `ok = failures.isEmpty`.
3. If neither decodes, or `version` is present but not `1`, or stdout is empty/malformed: `.error(...)`
   with the existing exit-code-aware remediation message. This is unchanged from today's behavior,
   just reached via an explicit version/shape check instead of "any decode failure."

This is a decode-time compatibility branch, not a second code path to maintain going forward — it
can be deleted once #745 (existing-site template migration) ships and old sites have upgraded.

### UI fallout

`BlockedDeploySheetView.swift` and `HealthBadgeView.swift` currently do
`Text(failure.detail)` / `Text(failure.remediation)` as non-optional. Since both fields become
optional:

- `Text(f.detail ?? f.message)` — always show *something* descriptive.
- The remediation `Text` is wrapped in `if let remediation = f.remediation { Text(remediation)... }`
  and omitted entirely when `nil`.
- `categoryIcon`/`categoryLabel` switches gain a `.other` case: a generic icon (`exclamationmark.triangle`)
  and the raw category string as the label, so an unrecognized/legacy category still renders
  something reasonable instead of failing to compile or falling through.

### Testing

- Unit tests for the new envelope: full success, mixed failures/warnings, unknown category →
  `.other`, missing/wrong `version`, empty stdout, malformed JSON.
- Legacy-array fallback test: today's `Issue[]` shape decodes correctly into the same `Outcome`
  shape (categories as `.other`).
- **Producer→consumer fixture test** (the gap this issue exists to close): a Swift test that runs
  the real `Resources/Template/scripts/pre-deploy-check.ts --json` via `npx tsx` against a small
  fixture site directory with a known PII hit and a clean case, feeds the actual captured stdout
  through `DeployCommand.parseScanReport`, and asserts on the resulting `Outcome` — not a
  hand-authored fixture string.
- Existing hand-authored fixtures in `PreDeployCheckTests`/`DeployCommandTests`/etc. are updated to
  the new envelope shape (`message` added, `detail`/`remediation` made optional in the JSON,
  `version: 1` added).

## Non-goals

- Reclassifying any check's severity (e.g. third-party-script error vs. warning).
- Writing `detail`/`remediation` copy for every check — optional fields may stay `nil` until a
  follow-up wants richer UI copy.
- Removing the four unused `ScanWarning` cases (`missingOgImage`, `maintenanceOverdue`,
  `seoCritical`, `seoWarning`) — they're harmless forward declarations, not this issue's concern.
- Any `.well-known` inventory, collision, or Worker-routing work — that's #744/#746, which build on
  this envelope but are separate specs.

## Target architecture invariants

- `pre-deploy-check.ts --json` and both Swift call sites agree on one versioned envelope.
- A real deploy's scan result decodes successfully and reflects the site's actual findings, not a
  decode-failure `.error`.
- An unrecognized category never crashes decoding or breaks a UI switch.
- Legacy (pre-#742) scaffolded sites keep working via the array fallback until they migrate.
- Malformed, empty, or unsupported-version output is always an explicit error, never a false pass.
