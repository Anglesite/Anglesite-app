#!/usr/bin/env bash
# Build ContainerSpike, run it unsigned, capture output.
#
# The original plan was a 3-config matrix (A: DevID baseline, B: MAS with .virtualization,
# C: MAS bare) signed three different ways. That approach turned out not to work — see
# docs/specs/2026-06-09-containerization-mas-subspike-notes.md ▸ "What the binary spike
# actually produced":
#
#   • A and B carry RESTRICTED entitlements (.virtualization, .vm.networking) — ad-hoc
#     signing with the hardened-runtime flag causes amfid to SIGKILL/SIGTRAP the binary
#     at launch, before main() ever runs.
#   • C has only app-sandbox — but a raw Mach-O CLI binary lacks a real .app bundle, so
#     sandboxd can't compute the ~/Library/Containers/<bundle-id>/ path and hangs.
#
# Empirically confirmed on macOS 27.0 / Apple Silicon 2026-06-09. The configs themselves
# can't be tested without a real Developer-ID identity + Apple-issued provisioning profile
# that grants the restricted entitlements — which is the gating ask the spike was supposed
# to inform a decision about. The fallback branch of #60 is the right call.
#
# This script keeps what's testable: the unsigned baseline. The probe output names the
# missing entitlement explicitly, which is the durable signal LocalContainerSiteRuntime
# can feature-detect against.
#
# When someone later has the provisioning profile in hand, the Entitlements/*.plist files
# are still the ground-truth list for what the production targets need.

set -euo pipefail

cd "$(dirname "$0")/.."
SPIKE_DIR="$PWD"
RESULTS_DIR="$SPIKE_DIR/results"
mkdir -p "$RESULTS_DIR"

echo "==> swift build"
swift build -c release --arch arm64

BIN="$(swift build -c release --arch arm64 --show-bin-path)/ContainerSpike"
if [[ ! -x "$BIN" ]]; then
    echo "FATAL: binary not at $BIN — did the build succeed?" >&2
    exit 1
fi

echo "==> run (unsigned baseline)"
"$BIN" \
    > "$RESULTS_DIR/unsigned.stdout.txt" \
    2> "$RESULTS_DIR/unsigned.stderr.txt" \
    || echo "(exit $?)" >> "$RESULTS_DIR/unsigned.stderr.txt"

echo
echo "==> result"
cat "$RESULTS_DIR/unsigned.stdout.txt"
echo
echo "Banner (stderr):"
cat "$RESULTS_DIR/unsigned.stderr.txt"
echo
echo "Saved to $RESULTS_DIR/unsigned.{stdout,stderr}.txt"
