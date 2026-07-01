#!/usr/bin/env bash
#
# Phase 4 — build the JS edit overlay into Resources/edit-overlay/overlay.js.
#
# JS/edit-overlay/ holds a small TypeScript module (selector + messages + overlay behavior)
# that the WKWebView injects into every previewed page. This script type-checks, bundles
# (esbuild → one IIFE), and drops the result where the Xcode "Copy Bundle Resources" phase
# can pick it up.
#
# Best-effort like the other build scripts: if Node isn't available or the install fails,
# warn and exit 0 so the Xcode build keeps going; `WebViewBridge.localDevConfiguration` logs
# the absence at runtime and the preview still loads (just without the overlay).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OVERLAY_DIR="$REPO_ROOT/JS/edit-overlay"
DEST_DIR="$REPO_ROOT/Resources/edit-overlay"

# Always materialize the destination so the Xcode resources phase resolves the folder ref
# even on a fresh checkout where the script hasn't run yet.
mkdir -p "$DEST_DIR"

if [[ ! -d "$OVERLAY_DIR" ]]; then
    echo "warning: $OVERLAY_DIR missing — skipping overlay build." >&2
    exit 0
fi

NPM=""
if command -v npm >/dev/null 2>&1; then
    NPM="$(command -v npm)"
else
    echo "warning: no npm found on PATH. Skipping overlay build." >&2
    exit 0
fi

cd "$OVERLAY_DIR"

# Install deps only when needed. esbuild's CLI binary is the canary — its presence means a
# full install ran. Avoids running `npm ci` on every Xcode build (slow); reruns after deps
# change (esbuild bin is gone after a clean).
if [[ ! -x "$OVERLAY_DIR/node_modules/.bin/esbuild" ]]; then
    echo "==> Installing JS/edit-overlay dependencies"
    if ! "$NPM" ci --prefer-offline --no-audit --no-fund 2>&1; then
        echo "warning: npm ci failed — skipping overlay build (preview still works, just without the overlay)." >&2
        exit 0
    fi
fi

echo "==> Building overlay → ${DEST_DIR#"$REPO_ROOT"/}/overlay.js"
"$NPM" run build

bytes=$(wc -c < "$DEST_DIR/overlay.js" | tr -d '[:space:]')
echo "Overlay bundle: $DEST_DIR/overlay.js (${bytes} bytes)"
