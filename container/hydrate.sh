#!/usr/bin/env bash
#
# Install a cloned site's npm dependencies as fast as possible by reusing the
# image's pre-baked toolchain (design decision #5b — skip npm ci on cold start).
#
#   • usable node_modules already present     -> nothing to do.
#   • node_modules has a foreign/broken native dependency
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

native_dependency_usable() {
    case "$1" in
        rollup)
            [ ! -f node_modules/rollup/package.json ] \
                || node -e "require('./node_modules/rollup/dist/native.js')"
            ;;
        esbuild)
            [ ! -f node_modules/esbuild/package.json ] \
                || node node_modules/esbuild/bin/esbuild --version
            ;;
        sharp)
            [ ! -f node_modules/sharp/package.json ] \
                || node -e "require('./node_modules/sharp')"
            ;;
    esac
}

if [ -d node_modules ]; then
    # A site repo may have been initialized after `npm install` on the host. If
    # that host-built tree was committed, optional native dependencies may be for
    # macOS/Windows rather than this Linux guest. Probe each native dependency the
    # template currently ships; this also catches an incomplete native install.
    incompatible_native_dependency=""
    for dependency in rollup esbuild sharp; do
        if ! native_dependency_usable "$dependency" >/dev/null 2>&1; then
            incompatible_native_dependency="$dependency"
            break
        fi
    done

    if [ -n "$incompatible_native_dependency" ]; then
        echo "WARN: existing node_modules has no usable $incompatible_native_dependency native binding for this container; reinstalling dependencies" >&2
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
