#!/usr/bin/env bash
#
# Phase 2 — copy the sibling Anglesite plugin into Resources/plugin/.
#
# Source defaults to ../anglesite (sibling under github.com/Anglesite/). Override
# with $ANGLESITE_PLUGIN_SRC for CI or alternative checkouts. The script is a
# best-effort sync: if the source is missing it emits a warning and exits 0 so
# the Xcode build keeps going; PluginRuntime surfaces the absence at runtime.
# Exception: a plugin that is FOUND but older than $MIN_PLUGIN_VERSION fails the
# build loudly — see the minimum-version guard below.
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

# Minimum-version guard: the app requires plugin features introduced in 1.3.0
# (get_component_model, used by the Component Editor). A MISSING plugin stays
# best-effort (handled above — PluginRuntime reports it at runtime), but bundling
# a plugin that IS present yet too old would ship an app whose edit pipeline
# fails in confusing ways at runtime — fail the build loudly instead.
MIN_PLUGIN_VERSION="1.3.0"
# plutil parses the JSON and extracts the top-level key specifically — a first-match
# grep could be fooled by a nested "version" (engines/mcpServers/…) appearing earlier
# in the manifest. This script only runs on macOS (Xcode build phase), so plutil is
# always present. Missing key / invalid JSON → empty, caught below.
PLUGIN_VERSION=$(plutil -extract version raw -o - "$SRC/.claude-plugin/plugin.json" 2>/dev/null || true)
if [[ -z "$PLUGIN_VERSION" ]]; then
    echo "error: couldn't read \"version\" from $SRC/.claude-plugin/plugin.json" >&2
    echo "       The app requires plugin >= $MIN_PLUGIN_VERSION; refusing to bundle an unidentifiable plugin." >&2
    exit 1
fi
# sort -V orders versions numerically (1.2.0 < 1.10.0); the min version must sort first (or equal).
if [[ "$(printf '%s\n%s\n' "$MIN_PLUGIN_VERSION" "$PLUGIN_VERSION" | sort -V | head -n 1)" != "$MIN_PLUGIN_VERSION" ]]; then
    echo "error: plugin at $SRC is version $PLUGIN_VERSION, but the app requires >= $MIN_PLUGIN_VERSION." >&2
    echo "       Update the plugin checkout (git -C \"$SRC\" pull) or point ANGLESITE_PLUGIN_SRC" >&2
    echo "       at a plugin release >= $MIN_PLUGIN_VERSION." >&2
    exit 1
fi
echo "==> Plugin version $PLUGIN_VERSION (requires >= $MIN_PLUGIN_VERSION) — OK"

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
    --exclude='template/' \
    "$SRC/" "$DEST/"

# Install the plugin's runtime dependencies into the bundle. The rsync above
# deliberately excludes `node_modules/` (huge, includes dev deps), so the
# bundled `server/index.mjs` would crash on `import '@modelcontextprotocol/sdk'`
# without this. Idempotent: skip when the SDK is already present and the
# source's `package-lock.json` hasn't changed.
#
# Best-effort like the rest: a failure here exits 0 so the Xcode build keeps
# going; `PreviewSession.startMCPClient` will surface the absence at runtime.
LOCK_STAMP="$DEST/.deps-from-lock"
SRC_LOCK_HASH=$(shasum "$SRC/package-lock.json" 2>/dev/null | awk '{print $1}' || true)
CURRENT_LOCK_HASH=$(cat "$LOCK_STAMP" 2>/dev/null || true)

if [[ -d "$DEST/node_modules/@modelcontextprotocol/sdk" && -n "$SRC_LOCK_HASH" && "$SRC_LOCK_HASH" == "$CURRENT_LOCK_HASH" ]]; then
    echo "==> Plugin deps already current (lockfile unchanged). Skipping npm install."
else
    NPM=""
    if command -v npm >/dev/null 2>&1; then
        NPM="$(command -v npm)"
    fi

    if [[ -z "$NPM" ]]; then
        echo "warning: no npm available on PATH — bundled plugin will be missing runtime deps." >&2
        echo "         The MCP server won't start; the in-app overlay edits will fail." >&2
    else
        echo "==> Installing plugin runtime deps into $DEST (npm --omit=dev)"
        if ( cd "$DEST" && "$NPM" install --omit=dev --no-audit --no-fund --loglevel=error --prefer-offline ); then
            [[ -n "$SRC_LOCK_HASH" ]] && echo "$SRC_LOCK_HASH" > "$LOCK_STAMP"
        else
            echo "warning: npm install failed in $DEST — MCP server won't start." >&2
        fi
    fi
fi

# Stamp the copy with the source commit so PluginRuntime can report what's
# bundled (handy in the debug pane and bug reports).
if git -C "$SRC" rev-parse HEAD >/dev/null 2>&1; then
    git -C "$SRC" rev-parse HEAD > "$DEST/.bundled-from-commit"
fi
date -u +%Y-%m-%dT%H:%M:%SZ > "$DEST/.bundled-at"

echo "==> Plugin bundled at $DEST"
