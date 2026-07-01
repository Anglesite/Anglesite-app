# iOS Thin Client Readiness Audit

**Issues:** [#59](https://github.com/Anglesite/Anglesite-app/issues/59), [#71](https://github.com/Anglesite/Anglesite-app/issues/71)  
**Scope:** Phase 5 preflight for the remote-only iOS/iPadOS app target.

## Purpose

#71 is a new iOS thin client, not a conditional build of the existing macOS shell. The iOS app should
host SwiftUI plus `WKWebView` via `UIViewRepresentable`, drive `RemoteSandboxSiteRuntime`, and avoid
host subprocesses, local container runtime code, security-scoped package access, and AppKit-only
targets.

Run:

```sh
scripts/audit-ios-thin-client-readiness.sh
```

Expected today:

- The command exits 0.
- It lists the remote-runtime and bridge pieces already present.
- It lists the remaining blockers, including package/project platform declarations, iOS app bundle
  metadata, FSEvents/security-scoped/Core host runtime surfaces, and AppKit-bound intents code.

The `AnglesiteIOS` shell target must not depend on `AnglesiteBridge` until the bridge can be split
away from `AnglesiteCore`; otherwise SwiftPM pulls macOS-only host runtime files into iOS builds.

## Readiness Gate

When adding the iOS target, run:

```sh
scripts/audit-ios-thin-client-readiness.sh --expect-ready
```

Expected once #71 is ready to compile:

- The command exits 0.
- It prints `No tracked iOS thin-client blockers remain.`
- The new iOS target links only the shared pieces it can actually use: `AnglesiteBridge` boundary
  code, the HTTP MCP client, `SandboxControlClient`, and `RemoteSandboxSiteRuntime`.

Fail if `--expect-ready` exits 0 while the target still links host runtime, local container,
FSEvents, AppKit-only, or security-scoped package code.

## Evidence To Record On #71

- Output of `scripts/audit-ios-thin-client-readiness.sh --expect-ready`.
- The new iOS scheme build command and result.
- Confirmation that preview uses `WKWebView` through `UIViewRepresentable`.
- Confirmation that runtime selection is remote-only and never reaches `LocalSiteRuntime`,
  `ProcessSupervisor`, `NodeRuntime`, or `LocalContainerSiteRuntime`.
- Confirmation that the Cloudflare Worker URL/API token path uses iOS Keychain storage.
