# ContainerSpike

Minimal harness for the [#60 Apple-Containerization-under-MAS sub-spike](../../docs/specs/2026-06-09-containerization-mas-subspike-notes.md). One Swift CLI binary, three codesign passes with different entitlements, JSON-lines output you can paste back into the notes.

## Why a CLI, not a SwiftUI app

The question this spike answers is "does the sandbox + entitlement gate let Virtualization.framework run?" The answer is the same whether the caller is AppKit or `main.swift`. Stripping the UI keeps the test matrix to one axis (signing), which is the only axis we actually care about.

## What it tests

Three tiers, run in sequence in one binary execution. All three are emitted regardless of failure — tier 1 denying doesn't skip tier 2 — so we capture *every* sandbox/entitlement violation in one run.

| Tier | What it probes | Signal it gives |
|---|---|---|
| 1 | `VZVirtualMachineConfiguration` instantiation + `validate()` | Does the sandbox let us reach `Virtualization.framework` at all? Denial means `com.apple.security.virtualization` is missing or unhonored. |
| 2 | `VZBridgedNetworkInterface.networkInterfaces` + bridge attachment construction | Does the framework expose bridged networking? Config-time success is necessary-not-sufficient — the real gate fires at VM start (tier 3). |
| 3 | Full Linux container boot via `apple/containerization` (Alpine, `echo hello`) | The end-to-end test. Currently a TODO — fill in by adapting `cctl/RunCommand.swift` from the upstream package. Tiers 1+2 give the entitlement signal even with tier 3 stubbed. |

## How to run

Requires macOS 26+ on Apple Silicon (the design doc's "capable Mac" floor). The `apple/containerization` Swift package targets macOS 15+, but the framework's behavior under sandboxing on older macOS isn't what we're testing.

```sh
cd Spikes/ContainerSpike
./scripts/run-matrix.sh
```

The script builds once with `swift build -c release --arch arm64`, then for each of three entitlements plists:

1. Copies the binary to `results/<config>.bin`
2. `codesign --sign -` with the config's entitlements plist (ad-hoc — restricted entitlements aren't *honored* without an Apple provisioning profile, but the sandbox attribute itself is enforced)
3. Runs the binary, captures stdout (JSON probe results), stderr (banner), and the system `log show` window filtered to `sandboxd` violations
4. Prints a one-line-per-config summary

Output lands in `results/`. The script prints a summary line per configuration like:

```
A-devid-baseline:       1-virtualization=ok 2-vmnet-bridged=ok 3-container-boot=error …
B-mas-virt-only:        1-virtualization=ok 2-vmnet-bridged=ok 3-container-boot=denied …
C-mas-bare:             1-virtualization=denied 2-vmnet-bridged=denied …
```

## Interpreting results

- **A (DevID baseline) all `ok`** → confirms the local-container path is viable on DevID. Cold-boot wall-clock from the elapsed-ms fields gives the "warming…" UX threshold for §0 decision 5b.
- **B (MAS, virt-only) tier-1 `ok`, tier-2 or tier-3 `denied`** → confirms wall 3 from the notes: `com.apple.vm.networking` is the hard block. Capture the exact error string for `LocalContainerSiteRuntime` to feature-detect against.
- **C (MAS, bare) tier-1 `denied`** → confirms wall 2 from the notes: even `com.apple.security.virtualization` won't get us past the sandbox under ad-hoc signing without a provisioning profile.

Anything that *doesn't* match the prediction is a finding worth flagging in the notes.

## Files

```
Spikes/ContainerSpike/
├── Package.swift                 SwiftPM, depends on apple/containerization
├── Sources/ContainerSpike/
│   └── main.swift                three-tier probe + JSON emitter
├── Entitlements/
│   ├── A-devid-baseline.plist    no sandbox, both restricted entitlements
│   ├── B-mas-virt-only.plist     sandbox + .virtualization, no .vm.networking
│   └── C-mas-bare.plist          sandbox only (mirrors current AnglesiteMAS.entitlements)
├── scripts/
│   └── run-matrix.sh             build → 3× sign → 3× run → summarize
├── results/                      (gitignored, created on first run)
└── README.md                     this file
```

## Cleanup

When the spike resolves, either:

- Promote the findings to `docs/specs/2026-06-09-containerization-mas-subspike-notes.md` and delete `Spikes/ContainerSpike/`, or
- Keep the harness if we want to re-run it on future macOS / Containerization releases (cheap to keep, but adds a `swift-tools-version: 6.0` SwiftPM resolution to the workspace).
