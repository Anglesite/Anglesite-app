#!/usr/bin/env bash
#
# Phase 10 — verify every intra-book link/asset reference in the Anglesite Help Book
# resolves to a file that exists. Cheap guard against dead links as pages grow.
#
# Scans each .html under en.lproj for href="..." and src="..." values, ignores external
# (http/https/mailto) and pure "#anchor" refs, strips any "#fragment" suffix, resolves the
# remainder relative to the HTML file's directory, and asserts the target exists.
#
# Exit 0 = all links resolve. Exit 1 = at least one dead link (prints each).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
LPROJ="$REPO_ROOT/Resources/Anglesite.help/Contents/Resources/en.lproj"

if [[ ! -d "$LPROJ" ]]; then
    echo "error: help book lproj not found at $LPROJ" >&2
    exit 1
fi

fail=0
while IFS= read -r html; do
    dir=$(dirname "$html")
    # Pull href/src targets; one per line.
    grep -oE '(href|src)="[^"]+"' "$html" | sed -E 's/^(href|src)="//; s/"$//' | while IFS= read -r ref; do
        case "$ref" in
            http://*|https://*|mailto:*|"#"*) continue ;;
        esac
        target="${ref%%#*}"          # strip #fragment
        [[ -z "$target" ]] && continue
        if [[ ! -e "$dir/$target" ]]; then
            echo "DEAD LINK: ${html#"$REPO_ROOT"/} -> $ref" >&2
            echo "x" >> "$REPO_ROOT/.help-link-failures"
        fi
    done
done < <(find "$LPROJ" -name '*.html')

if [[ -f "$REPO_ROOT/.help-link-failures" ]]; then
    fail=$(wc -l < "$REPO_ROOT/.help-link-failures" | tr -d '[:space:]')
    rm -f "$REPO_ROOT/.help-link-failures"
fi

if [[ "$fail" -gt 0 ]]; then
    echo "FAIL: $fail dead link(s)." >&2
    exit 1
fi
echo "OK: all help links resolve."
