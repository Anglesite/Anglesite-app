#!/usr/bin/env bash
#
# Phase 0 sign + notarize dry run. Closes acceptance criteria for issue #1.
#
# Prerequisites:
#   - Phase 0.5 complete: Anglesite.xcodeproj exists at the repo root.
#   - $TEAM_ID set to your Apple Developer Team ID (10 chars, e.g. ABCDE12345).
#   - $KEYCHAIN_PROFILE points at a notarytool credential profile previously
#     created with:
#       xcrun notarytool store-credentials "$KEYCHAIN_PROFILE" \
#         --apple-id <you@example.com> --team-id "$TEAM_ID" --password <app-pw>
#     Defaults to "AC_PASSWORD" to match docs/xcode-setup.md.
#
# Usage:
#   TEAM_ID=ABCDE12345 scripts/notarize-dry-run.sh
#
# Acceptance checklist (issue #1):
#   1. xcodebuild archive          -> .xcarchive
#   2. xcodebuild -exportArchive   -> signed .app
#   3. xcrun notarytool submit --wait -> status: Accepted
#   4. xcrun stapler staple        -> ticket attached
#   5. spctl --assess              -> source=Notarized Developer ID

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/Anglesite.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/Anglesite.app"
EXPORT_OPTIONS="$BUILD_DIR/exportOptions.plist"
EXPORT_OPTIONS_TEMPLATE="$SCRIPT_DIR/exportOptions.plist"

KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-AC_PASSWORD}"
SCHEME="${SCHEME:-Anglesite}"
CONFIGURATION="${CONFIGURATION:-Release}"

bail() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n=== %s ===\n' "$*"; }

[[ -n "${TEAM_ID:-}" ]] \
    || bail "TEAM_ID is unset. Export your 10-character Apple Developer Team ID and re-run."

command -v xcodegen >/dev/null \
    || bail "xcodegen not installed. brew install xcodegen"

xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1 \
    || bail "notarytool keychain profile '$KEYCHAIN_PROFILE' not found. Run: xcrun notarytool store-credentials '$KEYCHAIN_PROFILE' --apple-id <you> --team-id '$TEAM_ID' --password <app-specific-password>"

step "0/5 xcodegen generate"
(cd "$REPO_ROOT" && xcodegen generate)

mkdir -p "$BUILD_DIR"
sed "s/__TEAM_ID__/$TEAM_ID/g" "$EXPORT_OPTIONS_TEMPLATE" > "$EXPORT_OPTIONS"

step "1/5 xcodebuild archive"
xcodebuild \
    -project "$REPO_ROOT/Anglesite.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    archive

step "2/5 xcodebuild -exportArchive"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

[[ -d "$APP_PATH" ]] || bail "export produced no .app at $APP_PATH"

step "3/5 xcrun notarytool submit --wait"
xcrun notarytool submit "$APP_PATH" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

step "4/5 xcrun stapler staple"
xcrun stapler staple "$APP_PATH"

step "5/5 spctl --assess"
spctl --assess --type execute --verbose=4 "$APP_PATH" 2>&1 | tee /tmp/anglesite-spctl.log
grep -q "source=Notarized Developer ID" /tmp/anglesite-spctl.log \
    || bail "spctl did not report 'source=Notarized Developer ID'. See /tmp/anglesite-spctl.log."

printf '\nSUCCESS: %s is signed, notarized, and stapled.\n' "$APP_PATH"
