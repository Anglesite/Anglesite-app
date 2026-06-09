# ContainerSpike

Empirical harness for the [#60 Apple-Containerization-under-MAS investigation](../../docs/specs/2026-06-09-containerization-mas-subspike-notes.md). One Swift CLI binary that probes `Virtualization.framework` reachability, plus an unsigned-baseline run script.

## What this harness can actually test

Only the **unsigned baseline**. The original three-config matrix (DevID-baseline / MAS-with-virtualization / MAS-bare, all ad-hoc-signed) was shown empirically on 2026-06-09 to be untestable that way — `amfid` SIGKILL/SIGTRAPs ad-hoc binaries claiming restricted entitlements, and `sandboxd` hangs on raw CLI binaries with no `.app` bundle. Full write-up in the [subspike notes](../../docs/specs/2026-06-09-containerization-mas-subspike-notes.md).

What the unsigned-baseline run *does* give you: a clean, durable signal that `Virtualization.framework` refuses to validate any config without `com.apple.security.virtualization`. That error string is what `LocalContainerSiteRuntime` can feature-detect against to fall back to the Cloudflare path.

```sh
Spikes/ContainerSpike/scripts/run-unsigned.sh
# or, from inside the spike dir:
./scripts/run-unsigned.sh
```

Output lands in `results/unsigned.{stdout,stderr}.txt`.

## What the probe binary does

Three tiers, all run in one execution. JSON-line output (one record per tier) so future diff-against-baseline scripts have something stable to parse:

| Tier | What it probes |
|---|---|
| 1 | `VZVirtualMachineConfiguration.validate()` — does `Virtualization.framework` accept any call? Tier-1 `denied` with an "entitlement" mention = `.virtualization` missing. |
| 2 | `VZBridgedNetworkInterface.networkInterfaces` + bridge attachment construction. Config-time success is necessary-not-sufficient — the real `.vm.networking` gate fires at VM start. |
| 3 | Full Linux container boot via `apple/containerization`. **Currently stubbed** — needs ~20 LOC pulled from upstream `cctl/RunCommand.swift`. Only meaningful once `.virtualization` and `.vm.networking` are actually granted. |

## What the Entitlements/ plists are for

They're **not** runnable matrix configurations anymore (see above). They are **ground-truth documentation** of what the production targets would need:

| File | Used by (someday) | Contains |
|---|---|---|
| `A-devid-baseline.plist` | The `Anglesite` (DevID) target if it ships `LocalContainerSiteRuntime` | `.virtualization` + `.vm.networking` + hardened runtime, no sandbox |
| `B-mas-virt-only.plist` | A hypothetical MAS target that gets `.virtualization` from Apple but not `.vm.networking` | sandbox + `.virtualization` |
| `C-mas-bare.plist` | Mirror of current `Resources/AnglesiteMAS.entitlements` | sandbox + network client only |

Don't try to ad-hoc-sign with them; you will get amfid SIGKILL or sandboxd hangs.

## Re-running with a real provisioning profile (future)

If/when Anglesite gets an Apple-issued provisioning profile that grants `com.apple.security.virtualization` (and ideally `com.apple.vm.networking`), then:

1. Replace `codesign --sign -` with `codesign --sign "Developer ID Application: ..." --entitlements Entitlements/A-devid-baseline.plist --options runtime`.
2. Wrap the binary in a minimal `.app` bundle so `sandboxd` has a stable bundle id to compute the container path from.
3. Fill in tier 3 in `Sources/ContainerSpike/main.swift` with a real `LinuxContainer` boot adapted from `apple/containerization`'s `cctl/RunCommand.swift`.

That's the path to actually measure cold-boot wall-clock + the precise vmnet failure mode. None of it is on the critical path for #60's conclusion.

## Files

```
Spikes/ContainerSpike/
├── Package.swift                 SwiftPM, depends on apple/containerization
├── Sources/ContainerSpike/
│   └── main.swift                three-tier probe + JSON emitter
├── Entitlements/                 ground-truth docs (not runnable configs)
│   ├── A-devid-baseline.plist
│   ├── B-mas-virt-only.plist
│   └── C-mas-bare.plist
├── scripts/
│   └── run-unsigned.sh           build + run unsigned binary, capture output
├── results/                      (gitignored, created on first run)
└── README.md                     this file
```
