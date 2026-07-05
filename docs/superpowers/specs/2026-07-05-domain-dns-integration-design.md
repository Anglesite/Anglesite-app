# Domain (DNS) integration — deterministic Swift port

Part of #462 (Slice 3, epic #459 — retiring Claude Code in favor of deterministic
Swift + Apple Intelligence). Ports the plugin's `domain` skill
(`Anglesite/anglesite/skills/domain/SKILL.md`) to a Claude-free App Intent + GUI
wizard.

## Why this isn't an `IntegrationDescriptor`

The 11 integrations already in `IntegrationCatalog.all` (booking, contact,
donations, giscus, newsletter, consent, pwa, redirects, tracking, share,
podcast) are all declarative operations against the site's `Source/` git
repo: copy an Astro template file, inject a snippet, write a `.env`-style
config entry. They run once, at scaffold time, with no live network calls.

Domain/DNS management is different in kind: it's live Cloudflare API calls —
list current DNS records, add a record, delete a record — with no site-source
footprint at all. It doesn't belong in `IntegrationCatalog`; it's a sibling to
the existing **Harden** feature (`HardenModel`/`HardenSheetView`), which
already does "resolve zone from a typed domain → read zone state → build a
plan → apply writes via the Cloudflare API" for security settings (DNSSEC,
HSTS, WAF, etc.).

## Scope (full parity with the skill)

- View current DNS records, translated into plain-English purpose labels
  (website / email routing / spam prevention / verification / other) —
  mirrors the skill's "Translate the output into plain English" step.
- Add an arbitrary DNS record (type, name, content, TTL) — the general case
  the skill falls back to for "any other service."
- Delete a DNS record, with confirmation.
- Add a Bluesky handle-verification TXT record (`_atproto` / `did=...`).
- Add a Google site-verification record.

Bluesky and Google verification are **not separate code paths** — both are
the generic add-record flow with the form pre-filled (type/name/help text).
Google's own instructions vary between a TXT and a CNAME record depending on
the product, so there's no single fixed shape to hard-code beyond labeling
the flow and linking the right instructions.

Out of scope for this slice: email routing setup (already covered by the
`anglesite:email` skill/wizard direction, a separate issue), Cloudflare
Registrar domain search/registration (tracked by the `registrar`
`TokenCapability`, not requested here).

## Architecture

New `DomainModel` (`@Observable`, `@MainActor`) + `DomainSheetView`, presented
from `SiteWindowModel` via a new `openDomainManager()`, alongside the existing
`openIntegrationWizard()` and the Harden sheet's open method. Structurally a
copy of `HardenModel`'s shape:

```swift
enum Phase: Equatable {
    case idle
    case resolvingZone(domain: String)
    case loaded(records: [DNSRecord], domain: String, zoneID: String)
    case addingRecord(draft: DNSRecordDraft, domain: String, zoneID: String)
    case confirmingDelete(record: DNSRecord, domain: String, zoneID: String)
    case applying(domain: String)
    case failed(reason: String)
}
```

Token lookup (env var `CLOUDFLARE_API_TOKEN` first, then
`KeychainStore.readCloudflareToken()`) and `CloudflareError` → user-facing
message mapping are reused verbatim from `HardenModel` — not reimplemented.

Domain entry is manual text input, same as Harden's `domainInput` — the app
does not currently store a site's live domain anywhere in Swift-owned state
(`SITE_DOMAIN` lives in `.site-config`, which is template/plugin-owned).

## Cloudflare client changes

Two additions to the existing seam in `Sources/AnglesiteCore`:

```swift
// CloudflareReading
func listDNSRecords(zoneID: String, apiToken: String) async throws -> [DNSRecord]

// CloudflareWriting
func deleteDNSRecord(zoneID: String, recordID: String, apiToken: String) async throws
```

`addDNSRecord(zoneID:record:apiToken:)` already exists and is reused as-is.

New `DNSRecord` type (read model, distinct from the existing write-only
`DNSRecordPayload`):

```swift
public struct DNSRecord: Sendable, Equatable, Identifiable, Decodable {
    public let id: String
    public let type: String
    public let name: String
    public let content: String
    public let ttl: Int
    public let proxied: Bool
}
```

`listDNSRecords` calls `GET zones/{zoneID}/dns_records?per_page=100` — the
same endpoint the `.dns` `TokenCapability` probe already hits with
`per_page=1`; this slice is the first place that actually consumes the full
response body instead of just checking for a 2xx.

`HTTPCloudflareClient` implements both against the v4 REST API, matching the
existing method style (typed payload in, `CloudflareError` mapping on
failure, same auth header helper).

## UI

One sheet, opened from a new toolbar/menu entry point beside the existing
"Harden" and "Integrations" entries on `SiteWindow`:

- **Record list**: each row shows the plain-English purpose label, the raw
  type/name/content, and a delete button. Purpose labeling is a pure
  function (`DNSRecordLabeler` or similar) keyed on `type` + `name` pattern
  (e.g. `MX` → "Email routing", `TXT` at `_dmarc.*` → "Spam prevention
  (DMARC)", `TXT` at `_atproto` → "Bluesky verification", CNAME to
  `*.pages.dev`/`workers.dev` → "Website", fallback → "Other").
- **Add record** button opens an inline form: type picker (TXT/CNAME/A/AAAA/MX),
  name, content, TTL (default 1 = "Auto").
- **"Add Bluesky verification"** and **"Add Google verification"** quick
  actions pre-fill that same form (type=TXT, name=`_atproto` for Bluesky;
  type left for the user to pick for Google, since Google's instructions
  vary) with contextual help text, rather than skipping the form entirely —
  the user still confirms before it's written.
- **Delete** on a row asks for confirmation, then calls
  `deleteDNSRecord` and refreshes the list.

## App Intents

New `Sources/AnglesiteIntents/DomainIntents.swift`, matching the existing
`IntegrationIntents.swift` shape and registered the same way in the
operation descriptor registry:

- `ListDNSRecordsIntent` — returns the plain-English record summary for a
  given site/domain.
- `AddDNSRecordIntent` — parameters: type, name, content, optional TTL.
- `DeleteDNSRecordIntent` — parameter: record identifier (from a prior list).

These call into the same `DomainModel`/Cloudflare seam as the GUI, not a
separate implementation.

## Error handling

Identical to `HardenModel.cloudflareErrorMessage`: no-token, unauthorized
(missing DNS Read/Edit permission on the token), zone-not-found, generic
HTTP status, malformed response. No new error taxonomy.

## Testing

- `HTTPCloudflareClientTests`: `listDNSRecords` (success, empty, malformed
  JSON) and `deleteDNSRecord` (success, 404, unauthorized) against a mock
  transport, matching existing test style for `addDNSRecord`/`zoneState`.
- `DomainModelTests`: phase transitions (idle → resolvingZone → loaded,
  add → applying → loaded, delete confirmation → applying → loaded, error
  paths) against fake `CloudflareReading`/`CloudflareWriting`, mirroring
  `HardenModelTests`.
- `DomainIntentsTests`: one test per intent verifying it drives the same
  model calls, mirroring `IntegrationIntentsTests`.
- A pure-function test suite for the purpose-labeling logic (`DNSRecordLabeler`)
  covering the fixed patterns above plus an unrecognized-record fallback.
