#!/usr/bin/env bash
# Build ContainerSpike once, codesign it three ways, run each, capture output.
# Output lands in Spikes/ContainerSpike/results/<config>-{stdout,stderr,sandboxd}.txt
# so you can diff outcomes across configurations.
#
# Run from anywhere — script resolves its own location.
set -euo pipefail

cd "$(dirname "$0")/.."
SPIKE_DIR="$PWD"
RESULTS_DIR="$SPIKE_DIR/results"
mkdir -p "$RESULTS_DIR"

# ── 1. Build (Release, arm64 — apple/containerization is Apple-Silicon-only) ─────────────────
echo "==> swift build"
swift build -c release --arch arm64

BIN="$(swift build -c release --arch arm64 --show-bin-path)/ContainerSpike"
if [[ ! -x "$BIN" ]]; then
    echo "FATAL: binary not at $BIN — did the build succeed?" >&2
    exit 1
fi

# ── 2. Run the three configurations ────────────────────────────────────────────────────────
for cfg in A-devid-baseline B-mas-virt-only C-mas-bare; do
    plist="$SPIKE_DIR/Entitlements/$cfg.plist"
    stamped_bin="$RESULTS_DIR/$cfg.bin"

    echo "==> $cfg"
    cp "$BIN" "$stamped_bin"
    # Ad-hoc sign with the configuration's entitlements. Restricted entitlements (.virtualization,
    # .vm.networking) won't be *honored* without a provisioning profile from Apple — codesign
    # accepts them in the plist but the system enforces them based on the cert chain. For the
    # MAS-like configs B and C, ad-hoc is enough to trigger the sandbox at runtime.
    codesign --force --sign - --entitlements "$plist" --options runtime --timestamp=none "$stamped_bin" 2>&1 \
        | tee "$RESULTS_DIR/$cfg.sign.txt"

    # Run. Capture stdout (one JSON line per probe) + stderr (banner) separately.
    # Also tail Console for sandboxd violations during the run — useful for config C in particular.
    LOG_BEFORE="$(date '+%s')"
    "$stamped_bin" \
        > "$RESULTS_DIR/$cfg.stdout.txt" \
        2> "$RESULTS_DIR/$cfg.stderr.txt" \
        || echo "(exit $?)" >> "$RESULTS_DIR/$cfg.stderr.txt"
    LOG_AFTER="$(date '+%s')"

    # Best-effort sandboxd log capture for the run window.
    log show --predicate 'subsystem == "com.apple.sandbox" OR process == "sandboxd"' \
        --start "@$LOG_BEFORE" --end "@$LOG_AFTER" --style compact 2>/dev/null \
        > "$RESULTS_DIR/$cfg.sandboxd.txt" || true

    echo "    -> $RESULTS_DIR/$cfg.{stdout,stderr,sandboxd}.txt"
done

# ── 3. Summarize ──────────────────────────────────────────────────────────────────────────
echo
echo "==> summary"
for cfg in A-devid-baseline B-mas-virt-only C-mas-bare; do
    printf "  %-22s" "$cfg:"
    if [[ -s "$RESULTS_DIR/$cfg.stdout.txt" ]]; then
        # Each probe emits one JSON line; show tier+outcome on one row.
        awk -F'"' '/"tier"/{
            tier=""; outcome="";
            for(i=1;i<=NF;i++){
                if($i=="tier"){tier=$(i+2)}
                if($i=="outcome"){outcome=$(i+2)}
            }
            printf "%s=%s ", tier, outcome
        } END { print "" }' "$RESULTS_DIR/$cfg.stdout.txt"
    else
        echo "(no stdout — see $cfg.stderr.txt)"
    fi
done

echo
echo "Done. Paste $RESULTS_DIR/*.{stdout,sandboxd}.txt into the subspike notes."
