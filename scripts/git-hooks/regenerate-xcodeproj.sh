#!/usr/bin/env bash
# Shared logic for the post-merge / post-checkout / post-rewrite hooks.
# Regenerates Anglesite.xcodeproj via xcodegen when project.yml or a source tree
# Xcode cares about has changed between $1 and $2 (old/new ref).
#
# Args: $1 = old ref, $2 = new ref. If either is missing, regenerate unconditionally.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

old_ref="${1:-}"
new_ref="${2:-}"

# Paths whose changes warrant a project regeneration. Keep this list aligned with
# the `sources:` globs in project.yml.
watched=(project.yml Sources Resources/Info.plist Resources/Assets.xcassets)

if [[ -n "$old_ref" && -n "$new_ref" && "$old_ref" != "0000000000000000000000000000000000000000" ]]; then
  if git diff --quiet "$old_ref" "$new_ref" -- "${watched[@]}" 2>/dev/null; then
    exit 0
  fi
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "[git-hook] xcodegen not found on PATH — skipping project regeneration." >&2
  echo "[git-hook] Install with: brew install xcodegen" >&2
  exit 0
fi

echo "[git-hook] Regenerating Anglesite.xcodeproj via xcodegen…"
xcodegen generate --quiet
