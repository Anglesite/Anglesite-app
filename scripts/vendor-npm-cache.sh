#!/usr/bin/env bash
#
# Phase 1 — build a primed npm cache tarball into Resources/npm-cache/cache.tar.gz.
#
# To avoid a cold network install on first launch, we ship a gzipped tarball of an
# npm cache directory pre-filled by installing the bundled plugin's (and any site
# template's) dependencies. At launch the app extracts it into
#   ~/Library/Application Support/Anglesite/npm-cache/
# and points `npm --cache` at it (see AnglesiteCore/NodeModulesCache).
#
# DEFAULT-ON: this runs as part of every build. Set ANGLESITE_BUILD_NPM_CACHE=0 to
# skip it (e.g. an offline checkout or a fast local iteration build). Measured cost
# (build-plan Phase 1 step 5): the primed cache is ~768MB raw → ~264MB gzipped — over
# the original 100MB DMG-bloat budget, accepted as the price of offline first-launch
# (decided 2026-05-29). It is idempotent: it rebuilds only when the bundled plugin
# commit (Resources/plugin/.bundled-from-commit) changes, so a normal incremental
# build skips the ~1min install.
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
TARBALL="$DEST_DIR/cache.tar.gz"
VERSION_FILE="$DEST_DIR/version.txt"

# Always materialize the destination directory: it's referenced (optionally) by the Xcode
# target's resources phase, which still fails at build time on a missing folder reference even
# when XcodeGen marked it optional. An empty dir is harmless — NodeModulesCache treats "no
# cache.tar.gz inside" as `.noBundledArchive`.
mkdir -p "$DEST_DIR"

# Drop any stale uncompressed artifact from the pre-gzip format so it doesn't ride along in the
# bundle (NodeModulesCache only reads cache.tar.gz now).
rm -f "$DEST_DIR/cache.tar"

if [[ "${ANGLESITE_BUILD_NPM_CACHE:-1}" == "0" ]]; then
    echo "==> vendor-npm-cache: skipped (ANGLESITE_BUILD_NPM_CACHE=0)."
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

# Pick an npm. Also prepend the chosen npm's directory to PATH — under Xcode's stripped
# PATH (`/usr/bin:/bin:...`), `#!/usr/bin/env node` shebangs in npm-spawned tools fail to
# resolve. Putting the vendored bin on PATH first keeps the whole pipeline self-contained.
if [[ -x "$REPO_ROOT/Resources/node-runtime/bin/npm" ]]; then
    NPM="$REPO_ROOT/Resources/node-runtime/bin/npm"
    export PATH="$REPO_ROOT/Resources/node-runtime/bin:$PATH"
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
{ find "$PLUGIN_DIR" -name package.json -not -path '*/node_modules/*' -print0 2>/dev/null; \
  find "$REPO_ROOT/Resources/Template" -name package.json -not -path '*/node_modules/*' -print0 2>/dev/null; \
} | while IFS= read -r -d '' pkgjson; do
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
tar -czf "$TARBALL" -C "$CACHE" .
echo "$plugin_version" > "$VERSION_FILE"

size=$(du -sh "$TARBALL" 2>/dev/null | awk '{print $1}')
echo
echo "Primed npm cache: $TARBALL (${size:-?}, version $plugin_version)"
echo "  note: ~264MB gzipped, bundled by default — set ANGLESITE_BUILD_NPM_CACHE=0 to skip."
