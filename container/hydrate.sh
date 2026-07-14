#!/usr/bin/env bash
#
# Install a cloned site's npm dependencies as fast as possible by reusing the
# image's pre-baked toolchain (design decision #5b — skip npm ci on cold start).
#
#   • usable node_modules already present     -> nothing to do.
#   • node_modules has a foreign/broken Rollup native binding
#                                               -> discard and reinstall.
#   • lockfile identical to the baked template -> expand the baked node_modules
#                                                 archive (zero install — the common
#                                                 case for template-derived sites).
#   • otherwise                                -> npm ci/install against the warm
#                                                 npm cache (offline-first).

set -euo pipefail

SITE_DIR="${1:-${SITE_DIR:-/workspace}}"
BAKED="${ANGLESITE_HOME:-/opt/anglesite}/baked"
BAKED_ARCHIVE="${ANGLESITE_HOME:-/opt/anglesite}/baked-node-modules.tar"
cd "$SITE_DIR"

if [ -d node_modules ]; then
    # A site repo may have been initialized after `npm install` on the host. If
    # that host-built tree was committed, Rollup's optional native dependency is
    # for macOS/Windows rather than this Linux guest. Requiring Rollup's loader is
    # a cheap architecture check and also catches an incomplete native install.
    if [ -f node_modules/rollup/dist/native.js ] \
       && ! node -e "require('./node_modules/rollup/dist/native.js')" >/dev/null 2>&1; then
        echo "WARN: existing node_modules has no usable Rollup native binding for this container; reinstalling dependencies" >&2
        rm -rf node_modules
    else
        echo "==> node_modules already present and usable; skipping install"
        exit 0
    fi
fi

if [ -f package-lock.json ] && [ -f "$BAKED/package-lock.json" ] \
   && cmp -s package-lock.json "$BAKED/package-lock.json"; then
    if [ -f "$BAKED_ARCHIVE" ]; then
        echo "==> Lockfile matches the pre-baked toolchain; expanding baked node_modules (zero install)"
        tar -xf "$BAKED_ARCHIVE"
        exit 0
    fi

    # Compatibility with images built before the toolchain was archived.
    if [ -d "$BAKED/node_modules" ]; then
        echo "==> Lockfile matches the pre-baked toolchain; reusing baked node_modules (zero install)"
        # Hardlink for speed; fall back to a copy if /workspace is a separate device.
        cp -al "$BAKED/node_modules" ./node_modules 2>/dev/null \
            || cp -a "$BAKED/node_modules" ./node_modules
        exit 0
    fi

    echo "==> Pre-baked node_modules unavailable; using the warm npm cache"
fi

if [ -f package-lock.json ]; then
    echo "==> npm ci (warm cache, offline-first)"
    npm ci --prefer-offline
else
    echo "==> npm install (warm cache, offline-first)"
    npm install --prefer-offline
fi
