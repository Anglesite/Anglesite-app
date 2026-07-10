#!/usr/bin/env bash
# Build GitPackageSpike, wrap it in a real .app bundle, ad-hoc sign it with app-sandbox
# entitlements, and run it via `open` — the same methodology #640 itself used to get a real
# sandbox container attached (a bare Mach-O CLI binary makes sandboxd hang instead, per
# Spikes/ContainerSpike's prior finding).
#
# Also runs the identical binary unsigned/unsandboxed first, as a control.
set -euo pipefail

cd "$(dirname "$0")/.."
SPIKE_DIR="$PWD"
RESULTS_DIR="$SPIKE_DIR/results"
BUNDLE_ID="io.dwk.anglesite.spikes.gitpackage"
CONTAINER_DIR="$HOME/Library/Containers/$BUNDLE_ID"
mkdir -p "$RESULTS_DIR"

echo "==> swift build"
swift build -c release --arch arm64

BIN="$(swift build -c release --arch arm64 --show-bin-path)/GitPackageSpike"
[[ -x "$BIN" ]] || { echo "FATAL: binary not at $BIN — did the build succeed?" >&2; exit 1; }

echo
echo "==> control: unsigned, unsandboxed run (tier B has no pre-seeded repo, so it's skipped)"
"$BIN" \
    > "$RESULTS_DIR/control.stdout.txt" \
    2> "$RESULTS_DIR/control.stderr.txt" \
    || echo "(exit $?)" >> "$RESULTS_DIR/control.stderr.txt"
CONTROL_RESULT="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'gitpackagespike-result.json' -print -quit 2>/dev/null || true)"
if [[ -n "$CONTROL_RESULT" ]]; then
    cp "$CONTROL_RESULT" "$RESULTS_DIR/control-result.json"
    echo "control result:"
    cat "$RESULTS_DIR/control-result.json"
    rm -f "$CONTROL_RESULT"
else
    echo "control: no result file found at ${TMPDIR:-/tmp}/gitpackagespike-result.json" >&2
fi

echo
echo "==> building .app bundle"
APP="$RESULTS_DIR/GitPackageSpike.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/GitPackageSpike"
cp "$SPIKE_DIR/Entitlements/Info.plist" "$APP/Contents/Info.plist"

echo "==> pre-seeding tier B repo (real git, unsandboxed) inside the sandbox container's tmp dir"
# The container dir is a normal folder any process running as this user can write to — sandbox
# restricts what the *sandboxed app itself* can reach, not what other processes do to its
# container ahead of time. This lets tier B test the steady-state "commit onto existing
# history" path (NativeContentOperations) without routing through the very subprocess-git
# call #640 found broken.
CONTAINER_TMP="$CONTAINER_DIR/Data/tmp"
mkdir -p "$CONTAINER_TMP"
TIER_B_REPO="$CONTAINER_TMP/gitpackagespike-tierB-preseeded"
rm -rf "$TIER_B_REPO"
mkdir -p "$TIER_B_REPO"
git -C "$TIER_B_REPO" init -q
git -C "$TIER_B_REPO" config user.email "spike@anglesite.local"
git -C "$TIER_B_REPO" config user.name "GitPackageSpike setup"
echo "first file" > "$TIER_B_REPO/first-file.txt"
git -C "$TIER_B_REPO" add first-file.txt
git -C "$TIER_B_REPO" commit -q -m "Pre-seeded initial commit (real git, outside the sandbox)"

echo "==> ad-hoc signing with sandbox entitlements"
codesign --force --deep --sign - --entitlements "$SPIKE_DIR/Entitlements/sandboxed.plist" "$APP"
codesign -d --entitlements - "$APP" 2>&1 | grep -A2 app-sandbox || true

RESULT_JSON="$CONTAINER_TMP/gitpackagespike-result.json"
rm -f "$RESULT_JSON"

echo
echo "==> launching sandboxed .app via 'open' (mirrors #640's own repro methodology)"
open -W -a "$APP" --args "$TIER_B_REPO"

echo "==> polling for result file at $RESULT_JSON"
for _ in $(seq 1 20); do
    [[ -f "$RESULT_JSON" ]] && break
    sleep 0.5
done

if [[ -f "$RESULT_JSON" ]]; then
    cp "$RESULT_JSON" "$RESULTS_DIR/sandboxed-result.json"
    echo
    echo "==> sandboxed result:"
    cat "$RESULTS_DIR/sandboxed-result.json"
else
    echo "FATAL: no result file appeared at $RESULT_JSON after 10s — the sandboxed process" >&2
    echo "likely crashed or was blocked before it could write output. Check Console.app for" >&2
    echo "'GitPackageSpike' crash/sandbox-violation logs." >&2
    exit 1
fi

echo
echo "Saved to $RESULTS_DIR/{control,sandboxed}-result.json"
