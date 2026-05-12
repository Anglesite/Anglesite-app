#!/usr/bin/env bash
#
# Phase 1 — build a primed npm cache tarball into Resources/npm-cache/cache.tar.
#
# To avoid a cold network install on first launch, we ship a tarball of an npm
# cache directory pre-filled by installing the bundled plugin's (and any site
# template's) dependencies. At launch the app extracts it into
#   ~/Library/Application Support/Anglesite/npm-cache/
# and points `npm --cache` at it (see AnglesiteCore/NodeModulesCache).
#
# OPT-IN: this script is a no-op unless ANGLESITE_BUILD_NPM_CACHE=1. The tarball
# size budget is still unmeasured (build-plan Phase 1 step 5 open question — a
# >100MB tarball meaningfully bloats the DMG and every dev's checkout), so the
# build phase exists but stays dormant until the maintainer measures and opts in.
# When enabled it is idempotent: it rebuilds only when the bundled plugin commit
# (Resources/plugin/.bundled-from-commit) changes.
#
# Requires the bundled plugin (run scripts/copy-plugin.sh first) and a working
# `npm` — uses the vendored Resources/node-runtime/bin/npm if present, else the
# system npm. Best-effort throughout: any prerequisite gap warns and exits 0 so
# the Xcode build keeps going (NodeModulesCache reports the absence at runtime).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PLUGIN_DIR="$REPO_ROOT/Resources/plugin"
DEST_DIR="$REPO_ROOT/Resources/npm-cache"
TARBALL="$DEST_DIR/cache.tar"
VERSION_FILE="$DEST_DIR/version.txt"

# Always materialize the destination directory: it's referenced (optionally) by the Xcode
# target's resources phase, which still fails at build time on a missing folder reference even
# when XcodeGen marked it optional. An empty dir is harmless — NodeModulesCache treats "no
# cache.tar inside" as `.noBundledArchive`.
mkdir -p "$DEST_DIR"

if [[ "${ANGLESITE_BUILD_NPM_CACHE:-0}" != "1" ]]; then
    echo "==> vendor-npm-cache: skipped (set ANGLESITE_BUILD_NPM_CACHE=1 to build the primed cache)."
    exit 0
fi

if [[ ! -d "$PLUGIN_DIR" ]]; then
    echo "warning: $PLUGIN_DIR not found — run scripts/copy-plugin.sh first. Skipping npm cache." >&2
    exit 0
fi

# Version stamp: the plugin commit it was built from, else a hash of the plugin's
# package-lock files, else a UTC timestamp.
plugin_version=""
if [[ -f "$PLUGIN_DIR/.bundled-from-commit" ]]; then
    plugin_version=$(tr -d '[:space:]' < "$PLUGIN_DIR/.bundled-from-commit")
fi
if [[ -z "$plugin_version" ]]; then
    plugin_version=$(find "$PLUGIN_DIR" -name package-lock.json -not -path '*/node_modules/*' \
        -exec shasum {} + 2>/dev/null | sort | shasum | awk '{print $1}')
fi
[[ -n "$plugin_version" ]] || plugin_version=$(date -u +%Y%m%dT%H%M%SZ)

# Idempotent: nothing to do if already built for this version.
if [[ -f "$TARBALL" && -f "$VERSION_FILE" && "$(tr -d '[:space:]' < "$VERSION_FILE")" == "$plugin_version" ]]; then
    echo "==> vendor-npm-cache: cache.tar already current for $plugin_version. Skipping."
    exit 0
fi

# Pick an npm.
if [[ -x "$REPO_ROOT/Resources/node-runtime/bin/npm" ]]; then
    NPM="$REPO_ROOT/Resources/node-runtime/bin/npm"
elif command -v npm >/dev/null 2>&1; then
    NPM="$(command -v npm)"
else
    echo "warning: no npm found (neither vendored nor on PATH). Skipping npm cache." >&2
    exit 0
fi

if ! find "$PLUGIN_DIR" -name package.json -not -path '*/node_modules/*' | grep -q .; then
    echo "warning: no package.json under $PLUGIN_DIR — nothing to prime. Skipping." >&2
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CACHE="$TMP/npm-cache"
mkdir -p "$CACHE"

# Install each project into a throwaway copy, sharing one --cache so it accumulates
# every package tarball. --prefer-online to get fresh tarballs; --ignore-scripts so
# no postinstall hooks run during the build.
find "$PLUGIN_DIR" -name package.json -not -path '*/node_modules/*' -print0 | while IFS= read -r -d '' pkgjson; do
    dir=$(dirname "$pkgjson")
    work="$TMP/work-$RANDOM"
    mkdir -p "$work"
    cp "$pkgjson" "$work/"
    [[ -f "$dir/package-lock.json" ]] && cp "$dir/package-lock.json" "$work/"
    echo "==> Priming cache from ${dir#"$REPO_ROOT"/}"
    ( cd "$work" && "$NPM" install --cache "$CACHE" --prefer-online --no-audit --no-fund --ignore-scripts --loglevel=warn ) \
        || echo "  warn: npm install failed for ${dir#"$REPO_ROOT"/} — continuing with whatever reached the cache." >&2
done

mkdir -p "$DEST_DIR"
echo "==> Writing $TARBALL"
tar -cf "$TARBALL" -C "$CACHE" .
echo "$plugin_version" > "$VERSION_FILE"

size=$(du -sh "$TARBALL" 2>/dev/null | awk '{print $1}')
echo
echo "Primed npm cache: $TARBALL (${size:-?}, version $plugin_version)"
echo "  size-budget note: >100MB meaningfully bloats the DMG — see build-plan Phase 1 step 5."
