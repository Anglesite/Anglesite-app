#!/usr/bin/env bash
#
# Creates a smoke-test Anglesite site at ~/Sites/anglesite-smoke/, populated
# from the bundled plugin template with `node_modules` installed.
#
# Use this fixture to manually verify the dev-server lifecycle end-to-end:
# PreviewModel → AstroDevServer → ProcessSupervisor → window-close teardown.
# The template alone (without node_modules) leaves the preview in `.failed`
# and never exercises the subprocess code path.
#
# Idempotent: re-running mirrors any template changes (the source of truth
# lives in the sibling plugin repo) and runs `npm install` incrementally.
# Respects $ANGLESITE_PLUGIN_SRC the same way scripts/copy-plugin.sh does.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

PLUGIN_SRC="${ANGLESITE_PLUGIN_SRC:-$REPO_ROOT/../anglesite}"
TEMPLATE_SRC="$PLUGIN_SRC/template"
FIXTURE_DIR="$HOME/Sites/anglesite-smoke"

if [[ ! -d "$TEMPLATE_SRC" ]]; then
    echo "error: template not found at $TEMPLATE_SRC" >&2
    echo "       set ANGLESITE_PLUGIN_SRC to the plugin checkout root, or" >&2
    echo "       clone Anglesite/anglesite alongside this repo." >&2
    exit 1
fi

mkdir -p "$HOME/Sites"

echo "==> mirroring $TEMPLATE_SRC → $FIXTURE_DIR"
# Skip node_modules and build outputs in the mirror so the existing install
# stays put and the npm install below is incremental rather than full.
rsync -a \
    --exclude='node_modules/' \
    --exclude='.astro/' \
    --exclude='dist/' \
    --exclude='.wrangler/' \
    "$TEMPLATE_SRC/" "$FIXTURE_DIR/"

# Prefer the vendored Node runtime when available — that's what the running
# app uses, so it's the most accurate smoke environment. Fall back to PATH npm
# when the vendor step hasn't been run yet.
if [[ -x "$REPO_ROOT/Resources/node-runtime/bin/npm" ]]; then
    NPM="$REPO_ROOT/Resources/node-runtime/bin/npm"
    PATH="$REPO_ROOT/Resources/node-runtime/bin:$PATH"
    echo "==> using vendored node runtime"
else
    NPM=npm
    echo "==> using PATH npm (run scripts/vendor-node.sh for the vendored runtime)"
fi

cd "$FIXTURE_DIR"
echo "==> $NPM install --no-audit --no-fund --prefer-offline"
"$NPM" install --no-audit --no-fund --prefer-offline

cat <<EOF

✓ Smoke fixture ready: $FIXTURE_DIR

  Verify the dev-server lifecycle:
    1. Launch Anglesite (or use 'open Anglesite.xcodeproj' + ⌘R from Xcode).
    2. Open Folder… → pick anglesite-smoke (or it'll appear in the launcher
       since ~/Sites/anglesite-smoke is under the default sitesRoot).
    3. Preview should reach .ready and a node child should be parented by
       the app: ps -A -o pid,ppid,comm | awk '\$2 == <anglesite-pid>'
    4. Close the SiteWindow — the node child should be reaped within a few
       seconds (ProcessSupervisor.shutdownAll path).
    5. Quit the app — no orphan node processes should remain.
EOF
