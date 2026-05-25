#!/usr/bin/env bash
# End-to-end release pipeline for Anglesite.
#
# Bumps MARKETING_VERSION + CURRENT_PROJECT_VERSION, archives + notarizes via
# scripts/notarize-dry-run.sh, signs the resulting .zip with Sparkle's
# sign_update, publishes a GitHub Release with sparkle-* markers in the body,
# and regenerates build/appcast.xml via scripts/generate-appcast.sh.
#
# The appcast.xml is *not* pushed anywhere — that step is manual until the
# gh-pages branch + anglesite.dev custom domain are wired up (see docs/release.md).
#
# Usage:
#   scripts/release.sh 0.2.0
#
# Env:
#   TEAM_ID            (required) 10-char Apple Developer Team ID.
#   KEYCHAIN_PROFILE   (default AC_PASSWORD) notarytool keychain profile.

set -euo pipefail

VERSION="${1:-}"
[[ -n "$VERSION" ]] \
  || { echo "usage: scripts/release.sh <version>   e.g. 0.2.0" >&2; exit 64; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "error: version must be MAJOR.MINOR.PATCH (got '$VERSION')" >&2; exit 64; }
[[ -n "${TEAM_ID:-}" ]] \
  || { echo "error: TEAM_ID is unset. Export your 10-char Apple Developer Team ID." >&2; exit 64; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
APP_PATH="$BUILD_DIR/export/Anglesite.app"
ZIP_PATH="$BUILD_DIR/Anglesite-${VERSION}.zip"
APPCAST_PATH="$BUILD_DIR/appcast.xml"
TAG="v${VERSION}"
MIN_SYSTEM_VERSION="14.0"

cd "$REPO_ROOT"

bail() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n=== %s ===\n' "$*"; }

for cmd in gh jq xcodegen ditto; do
  command -v "$cmd" >/dev/null || bail "$cmd not on PATH"
done

git diff --quiet && git diff --cached --quiet \
  || bail "working tree has uncommitted changes — commit or stash before releasing"

branch="$(git rev-parse --abbrev-ref HEAD)"
[[ "$branch" == "main" ]] \
  || bail "releases must run from main (current: $branch)"

if gh release view "$TAG" >/dev/null 2>&1; then
  bail "release $TAG already exists on GitHub — bump the version"
fi

# Locate Sparkle's sign_update. The SourcePackages path is deterministic once
# the Anglesite scheme has been built at least once.
SIGN_UPDATE="$(find ~/Library/Developer/Xcode/DerivedData -name sign_update -path '*Sparkle*/bin/sign_update' 2>/dev/null | head -1)"
[[ -n "$SIGN_UPDATE" && -x "$SIGN_UPDATE" ]] \
  || bail "sign_update not found. Build the Anglesite scheme once so Sparkle is resolved, then re-run."

step "1/8 bump versions"
prev_build="$(grep -E '^\s*CURRENT_PROJECT_VERSION:' project.yml | awk '{print $2}')"
[[ "$prev_build" =~ ^[0-9]+$ ]] || bail "CURRENT_PROJECT_VERSION in project.yml is not a bare integer"
new_build=$((prev_build + 1))
echo "  MARKETING_VERSION:      → ${VERSION}"
echo "  CURRENT_PROJECT_VERSION: ${prev_build} → ${new_build}"
# macOS sed needs -i ''
sed -i '' "s|^\(\s*MARKETING_VERSION:\) .*|\1 \"${VERSION}\"|" project.yml
sed -i '' "s|^\(\s*CURRENT_PROJECT_VERSION:\) .*|\1 ${new_build}|" project.yml

step "2/8 archive + notarize + staple"
"${SCRIPT_DIR}/notarize-dry-run.sh"
[[ -d "$APP_PATH" ]] || bail "notarize-dry-run.sh did not produce $APP_PATH"

step "3/8 zip"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
zip_length="$(stat -f%z "$ZIP_PATH")"
echo "  → $ZIP_PATH ($zip_length bytes)"

step "4/8 sign_update"
# sign_update emits e.g.   sparkle:edSignature="ABC..." length="12345"
sig_line="$("$SIGN_UPDATE" "$ZIP_PATH")"
ed_signature="$(echo "$sig_line" | sed -n 's|.*sparkle:edSignature="\([^"]*\)".*|\1|p')"
[[ -n "$ed_signature" ]] || bail "could not parse edSignature from sign_update output: $sig_line"
echo "  edSignature: ${ed_signature:0:16}…"
echo "  length:      $zip_length"

step "5/8 commit version bump"
git add project.yml
git commit -m "release: ${VERSION}"

step "6/8 tag + push"
git tag -a "$TAG" -m "Anglesite ${VERSION}"
git push origin main "$TAG"

step "7/8 gh release create"
notes_file="$(mktemp)"
trap 'rm -f "$notes_file"' EXIT
cat >"$notes_file" <<EOF
Anglesite ${VERSION}

<!-- Machine-readable markers consumed by scripts/generate-appcast.sh. Do not edit. -->
<!-- sparkle-version: ${new_build} -->
<!-- sparkle-shortVersionString: ${VERSION} -->
<!-- sparkle-edSignature: ${ed_signature} -->
<!-- sparkle-length: ${zip_length} -->
<!-- sparkle-minimumSystemVersion: ${MIN_SYSTEM_VERSION} -->
EOF
gh release create "$TAG" "$ZIP_PATH" \
  --title "Anglesite ${VERSION}" \
  --notes-file "$notes_file"

step "8/8 regenerate appcast.xml"
"${SCRIPT_DIR}/generate-appcast.sh" "$APPCAST_PATH"

cat <<EOF

✅ Released ${TAG}.

Next steps (manual until gh-pages automation lands):
  1. Commit ${APPCAST_PATH} to the gh-pages branch:
       git worktree add ../Anglesite-app-pages gh-pages
       cp ${APPCAST_PATH} ../Anglesite-app-pages/appcast.xml
       (cd ../Anglesite-app-pages && git add appcast.xml && git commit -m "appcast: ${VERSION}" && git push)
  2. Confirm https://anglesite.dev/appcast.xml serves the updated feed.
  3. Test in-app "Check for Updates…" against the new release.
EOF
