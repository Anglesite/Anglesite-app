#!/usr/bin/env bash
#
# Phase 10 — build the Anglesite Help search index with hiutil.
#
# hiutil (shipped with macOS) indexes the help HTML into Anglesite.helpindex, which powers
# the Help-menu search field and Help Viewer search. Best-effort like the other vendor
# scripts: if hiutil is missing or indexing fails, warn and exit 0 so the Xcode build keeps
# going — the book still opens, just without search.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
LPROJ="$REPO_ROOT/Resources/Anglesite.help/Contents/Resources/en.lproj"

if [[ ! -d "$LPROJ" ]]; then
    echo "warning: help lproj missing at $LPROJ — skipping help index." >&2
    exit 0
fi

if ! command -v hiutil >/dev/null 2>&1; then
    echo "warning: hiutil not found — skipping help index (book still opens, no search)." >&2
    exit 0
fi

echo "==> Indexing Anglesite Help → en.lproj/Anglesite.helpindex"
# `-I corespotlight` builds the modern Spotlight index format that macOS Mojave+ expects;
# without it hiutil emits the legacy LSM format.
if ! hiutil -I corespotlight -Caf "$LPROJ/Anglesite.helpindex" "$LPROJ" 2>&1; then
    echo "warning: hiutil failed — skipping help index." >&2
    exit 0
fi
echo "Help index built: $LPROJ/Anglesite.helpindex"
