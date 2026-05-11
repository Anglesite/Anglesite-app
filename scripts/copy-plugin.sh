#!/usr/bin/env bash
#
# Phase 2 — copy the sibling Anglesite plugin into Resources/plugin/.
#
# Source defaults to ../anglesite (sibling under github.com/Anglesite/). Override
# with $ANGLESITE_PLUGIN_SRC for CI or alternative checkouts. The script is a
# best-effort sync: if the source is missing it emits a warning and exits 0 so
# the Xcode build keeps going; PluginRuntime surfaces the absence at runtime.
#
# rsync is used so node_modules, .git, and other heavy/private dirs are
# excluded and unchanged files are skipped on incremental builds.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
DEFAULT_SRC=$(cd "$REPO_ROOT/.." && pwd)/anglesite
SRC="${ANGLESITE_PLUGIN_SRC:-$DEFAULT_SRC}"
DEST="$REPO_ROOT/Resources/plugin"

if [[ ! -d "$SRC" ]]; then
    echo "warning: plugin source not found at $SRC" >&2
    echo "         set ANGLESITE_PLUGIN_SRC, or clone github.com/Anglesite/anglesite as a sibling." >&2
    echo "         Skipping plugin bundling — runtime will report 'plugin not bundled'." >&2
    exit 0
fi

# Sanity-check: the plugin marketplace manifest must exist. Otherwise we may be
# pointing at the wrong directory (e.g. an Anglesite *site*, not the plugin).
if [[ ! -f "$SRC/.claude-plugin/plugin.json" ]]; then
    echo "warning: $SRC does not look like the Anglesite plugin (no .claude-plugin/plugin.json)" >&2
    echo "         Skipping plugin bundling." >&2
    exit 0
fi

mkdir -p "$DEST"

echo "==> Copying plugin: $SRC -> $DEST"
rsync -a --delete \
    --exclude='node_modules/' \
    --exclude='.git/' \
    --exclude='.github/' \
    --exclude='.worktrees/' \
    --exclude='.serena/' \
    --exclude='.playwright-mcp/' \
    --exclude='.claude/' \
    --exclude='.DS_Store' \
    --exclude='dist/' \
    --exclude='build/' \
    --exclude='tests/' \
    --exclude='test/' \
    --exclude='*.log' \
    "$SRC/" "$DEST/"

# Stamp the copy with the source commit so PluginRuntime can report what's
# bundled (handy in the debug pane and bug reports).
if git -C "$SRC" rev-parse HEAD >/dev/null 2>&1; then
    git -C "$SRC" rev-parse HEAD > "$DEST/.bundled-from-commit"
fi
date -u +%Y-%m-%dT%H:%M:%SZ > "$DEST/.bundled-at"

echo "==> Plugin bundled at $DEST"
