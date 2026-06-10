#!/usr/bin/env bash
#
# Install a cloned site's npm dependencies as fast as possible by reusing the
# image's pre-baked toolchain (design decision #5b — skip npm ci on cold start).
#
#   • node_modules already present            -> nothing to do.
#   • lockfile identical to the baked template -> hardlink the baked node_modules
#                                                 (zero install — the common case
#                                                 for template-derived sites).
#   • otherwise                                -> npm ci/install against the warm
#                                                 npm cache (offline-first).

set -euo pipefail

SITE_DIR="${1:-${SITE_DIR:-/workspace}}"
BAKED="${ANGLESITE_HOME:-/opt/anglesite}/baked"
cd "$SITE_DIR"

if [ -d node_modules ]; then
    echo "==> node_modules already present; skipping install"
    exit 0
fi

if [ -f package-lock.json ] && [ -f "$BAKED/package-lock.json" ] \
   && cmp -s package-lock.json "$BAKED/package-lock.json"; then
    echo "==> Lockfile matches the pre-baked toolchain; reusing baked node_modules (zero install)"
    # Hardlink for speed; fall back to a copy if /workspace is a separate device.
    cp -al "$BAKED/node_modules" ./node_modules 2>/dev/null \
        || cp -a "$BAKED/node_modules" ./node_modules
    exit 0
fi

if [ -f package-lock.json ]; then
    echo "==> npm ci (warm cache, offline-first)"
    npm ci --prefer-offline
else
    echo "==> npm install (warm cache, offline-first)"
    npm install --prefer-offline
fi
