# Apple Containerization under the App Sandbox (MAS) — sub-spike notes

> **Status:** desk research + one preliminary binary run on macOS 27.0 / Apple Silicon (build 26A5353q). Harness lives at [`Spikes/ContainerSpike/`](../../Spikes/ContainerSpike/); the full 3-config matrix (`./scripts/run-matrix.sh`) still needs to be run to capture the MAS-bare and MAS-virt-only outcomes formally. **For #60 / #59.**
>
> ### Preliminary finding (2026-06-09, unsigned binary, no sandbox)
>
> Even running the spike **unsigned, outside any sandbox**, the Virtualization framework refuses `VZVirtualMachineConfiguration.validate()` with:
>
> > `VZErrorDomain: Invalid virtual machine configuration. The process doesn't have the "com.apple.security.virtualization" entitlement.`
>
> **The entitlement is the gate, not the sandbox.** This means *DevID also has to add `com.apple.security.virtualization` to ship the local-container path* — the entitlement requirement isn't an MAS-only concern. Practically: an Apple-issued provisioning profile is on the critical path for the DevID `LocalContainerSiteRuntime` even before MAS comes into the picture. (Doesn't change the recommendation below; it does make wall 2 *more* load-bearing.)

## TL;DR

**Prediction:** the MAS build of Anglesite will **not** be able to drive Apple Containerization locally. The DevID build can. Take the fallback branch in #60's "Output (decision)":

- `Anglesite` (DevID) → **`LocalContainerSiteRuntime`** (Apple Containerization).
- `AnglesiteMAS` (sandboxed) → **`RemoteSandboxSiteRuntime`** (Cloudflare), same code path as Intel / macOS < 26 / iOS.

Confidence: **high on "MAS can't ship local containers," moderate on the exact failure mode.** The binary spike below resolves the moderate-confidence pieces.

## Why MAS almost certainly can't ship the local path

Three independent walls, any one of which stops MAS. The third is the one without a workaround.

### Wall 1 — `container` CLI is structurally MAS-hostile

If we shipped the `apple/container` daemon model unchanged, it'd be a non-starter for MAS regardless of entitlements:

| Step | Where it lands | MAS-compatible? |
|---|---|---|
| `container` binary install | `/usr/local/bin/container` (admin password prompt) | ❌ no system-path writes from a sandboxed app |
| `container system start` | `launchctl bootstrap` of `com.apple.container.apiserver` etc. | ❌ no arbitrary launchd plist writes from a sandbox |
| XPC helpers | `container-core-images`, `container-network-vmnet`, `container-runtime-linux` | ❌ helpers expect to live outside the sandbox |
| Per-user data | `~/Library/Application Support/com.apple.container` | ⚠️ writeable only via the MAS app's own container, not a sibling |

This wall doesn't apply to the spike's actual question, because #60 proposes **embedding the `containerization` Swift package directly** (skipping the CLI daemon). But noted because anyone reading this later may otherwise reach for the CLI.

### Wall 2 — `com.apple.security.virtualization` is a restricted entitlement

The `containerization` package boots each container in a `Virtualization.framework` VM. That requires `com.apple.security.virtualization`. The entitlement *is* compatible with App Sandbox (Apple's own docs state "Sandbox is supported but not mandatory"), so the *technical* compatibility check passes. But:

- The entitlement is **restricted** — it must be authorized by a provisioning profile that Apple specifically issues.
- Historically granted case-by-case to virtualization-vendor apps. Not a blanket "tick a box in App Store Connect" capability.
- This is a possible-but-uncertain hurdle: surmountable, but slows down the MAS release timeline meaningfully if Apple takes weeks to respond.

This wall is **negotiable** with Apple. Wall 3 is not.

### Wall 3 — `com.apple.vm.networking` is the killer

The `container` daemon's networking model uses `vmnet` (`container-network-vmnet` XPC helper). The same will be true if we embed the Swift package directly and let it use its default networking — `vmnet` is what Apple's framework provides for container-on-VM networking with a routable IP.

`com.apple.vm.networking` is **explicitly restricted to developers of virtualization software** and requires a Developer Technical Support (DTS) incident with an Apple representative to grant. It is not on the standard App Store entitlement list. There is no documented path for a website-building app to qualify for it.

Without `vmnet`, the local-container path loses the "each container gets a dedicated IP → `http://<ip>:4321` direct" property that §0 of the design doc is built around. We'd have to invent a workaround — e.g. listen inside the guest on a host-shared socket via vsock and proxy through the host — that's no longer "use Apple Containerization as designed," and ends up roughly as much work as the Cloudflare path anyway.

**This is the load-bearing wall.** Even if Apple grants `com.apple.security.virtualization` for the MAS build, the lack of `com.apple.vm.networking` makes the local-container path architecturally unworkable.

## Precedent

| App | Uses Virtualization.framework? | Sandboxed? | Mac App Store? |
|---|---|---|---|
| ViableS (Howard Oakley) | Yes | Yes (for isolation) | **No** — author explicitly declined ("no benefit to users or to me, just more hassle") |
| UTM | Yes | Yes (DevID build) | Yes (UTM SE — but **emulation-only, no Hypervisor/Virtualization**) |
| VirtualBuddy, Tart, Lima | Yes | No | No |
| Parallels Desktop | Yes | Partial | Yes (App Store Edition with stripped feature set) |

The pattern: shipping a Virtualization-using app on MAS is **rare**, requires negotiation with Apple, and even when it works the App Store version is usually a stripped-down variant. Anglesite is not a virtualization vendor; the runway to make the case to Apple is much longer than the runway to ship via the Cloudflare path.

## What the binary spike still needs to confirm

Even with high desk-research confidence, run the spike before locking the plan. The binary outcomes resolve the *exact* error path, which matters for the user-facing fallback messaging and the implementation effort estimate.

Minimal test app — call it `ContainerSpike` — should be ~50 LOC:

```swift
import SwiftUI
import Containerization

@main struct ContainerSpikeApp: App {
    @State private var status = "idle"
    var body: some Scene {
        WindowGroup {
            VStack {
                Text(status).monospaced()
                Button("Boot Alpine") {
                    Task {
                        do {
                            // Pull a tiny image, boot a container, run `echo hello`, capture stdout.
                            // Use the LinuxContainer / ImageStore APIs directly from the Swift package.
                            status = "starting…"
                            // …
                            status = "ok: \(output)"
                        } catch {
                            status = "fail: \(error)"
                        }
                    }
                }
            }.padding()
        }
    }
}
```

Build it three ways, observe what happens:

| Configuration | Entitlements | Expected outcome |
|---|---|---|
| **A — DevID baseline** | `com.apple.security.virtualization` + `com.apple.vm.networking` (request via DTS first, or run unsigned for the spike) + hardened runtime | Should boot. Confirms we have the local path on DevID. |
| **B — MAS, virtualization only** | `app-sandbox` + `com.apple.security.virtualization` (no `vm.networking`) | Predicted: VM boots, but the container can't get an IP, fails at network setup. Captures the *exact* failure mode for the fallback messaging. |
| **C — MAS, neither restricted entitlement** | `app-sandbox` only (current `AnglesiteMAS.entitlements`) | Predicted: `Virtualization.framework` refuses to create the VM. Probably a sandbox violation in Console.app's `sandboxd` logs. |

Capture in this notes file:
- Whether (A) actually boots end-to-end (sanity check for the design's local path).
- Cold-boot time + memory footprint for a minimal container.
- The exact error string / sandbox violation from (B) and (C). That string becomes the substring `LocalContainerSiteRuntime` checks for to decide "fall back to remote."

A 1–2 hour pass should be enough.

## Recommended decisions to record (provisional, pending spike)

1. **#60 outcome ← fallback branch.** Update #60 with this prediction; mark it provisional until the binary spike confirms. Don't block #59's plan write-up on the binary spike — start the plan now under the fallback assumption.
2. **`SiteRuntime` selection at app start.**
   - `AnglesiteMAS` → always `RemoteSandboxSiteRuntime` (Cloudflare).
   - `Anglesite` → prefer `LocalContainerSiteRuntime` when macOS ≥ 26 + Apple Silicon, fall back to `RemoteSandboxSiteRuntime` otherwise.
3. **`com.apple.security.virtualization` is a DevID-only ask.** Don't try to file a MAS DTS request — Cloudflare path on MAS is shippable today and avoids the dependency on an Apple negotiation.
4. **Reframe the embedded-Node retirement on MAS.** Phase 10.1's bundled-Node re-sign is still needed *for as long as MAS continues to spawn Node directly*. If the runtime swings to the Cloudflare path on MAS (which it must, given the above), Node retires on MAS the moment `RemoteSandboxSiteRuntime` is the only runtime there — earlier than the design doc's "Phase 5 also retires Node on local" framing.
5. **Heads-up for the §0 paired plugin work (#63).** The HTTP/SSE MCP transport becomes the *only* MCP transport on MAS (no local-stdio fallback), so its reliability bar is higher than if it were a "remote-only" path. Worth flagging in #63.

## Open questions punted to the binary spike

- Does `Virtualization.framework` instantiation fail loudly (clear error) or silently (e.g., VM created but stuck) when `com.apple.security.virtualization` is absent under sandbox? Affects how `LocalContainerSiteRuntime`'s feature-detection should look.
- Is there *any* networking model the Containerization framework supports without `com.apple.vm.networking` — e.g., vsock-only with a host-side proxy? If yes, the wall is softer than predicted. Strongly doubt it, but the spike is cheap.
- Cold-boot wall-clock for an `astro dev`-ready container in (A). Sub-2-second per the framework's claims, but we'll want the actual number for the §0 "warming…" UX threshold (design-doc decision 5b).

## Sources

- Apple Containerization Swift package — [apple/containerization](https://github.com/apple/containerization), [`Package.swift`](https://github.com/apple/containerization/blob/main/Package.swift), [`LinuxContainer.swift`](https://github.com/apple/containerization/blob/main/Sources/Containerization/LinuxContainer.swift)
- `container` CLI architecture — [apple/container](https://github.com/apple/container), [technical-overview.md](https://github.com/apple/container/blob/main/docs/technical-overview.md), [DeepWiki: Installation](https://deepwiki.com/apple/container/2.1-installation)
- Apple docs — [Virtualization entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.virtualization), [vm.networking entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.vm.networking), [Adding the Virtualization Entitlement](https://developer.apple.com/documentation/virtualization/adding-the-virtualization-entitlement-to-your-project)
- Apple Developer Forums — ["How to request com.apple.vm.\* entitlements"](https://developer.apple.com/forums/thread/656411) (restricted, DTS-only, "virtualization software developers")
- Anil Madhavapeddy, ["Under the hood with Apple's new Containerization framework"](https://anil.recoil.org/notes/apple-containerisation)
- Howard Oakley, ["Sandbox and isolate your VMs with a new version of ViableS"](https://eclecticlight.co/2023/08/30/sandbox-and-isolate-your-vms-with-a-new-version-of-viables/) (precedent: sandboxed Virtualization app, DevID, no MAS plans)
