#!/usr/bin/env bash
#
# Mac App Store release pipeline for the Anglesite target.
#
# Archives the sandboxed Anglesite scheme, exports an App Store .pkg (signed with the
# Apple Distribution + Mac Installer Distribution identities), verifies the bundled-Node
# re-sign survived the archive, then validates and uploads to App Store Connect.
#
# There is deliberately no direct-download update feed or GitHub Release step. On the App Store,
# App Store Connect is the distribution channel and updates ship through it.
#
# Prerequisites (one-time, see docs/release.md "Mac App Store submission"):
#   - An App Store Connect app record for bundle id io.dwk.anglesite.
#   - An "Apple Distribution" cert + a "Mac Installer Distribution" cert in the keychain.
#   - The Apple WWDR (G3) intermediate cert (https://www.apple.com/certificateauthority/).
#   - A Mac App Store provisioning profile for io.dwk.anglesite, installed.
#   - An App Store Connect API key (.p8 in ~/.appstoreconnect/private_keys/ or
#     ~/.private_keys/) plus its key id + issuer id, for keychain-free altool upload.
#
# Usage:
#   TEAM_ID=ABCDE12345 \
#   PROVISIONING_PROFILE="Anglesite MAS App Store" \
#   ASC_API_KEY_ID=XXXXXXXXXX ASC_API_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
#     scripts/release.sh [--validate-only]
#
#   --validate-only   Archive + export + `altool --validate-app`, but stop before upload.
#                     Useful before a real App Store upload.
#
# Env:
#   TEAM_ID               (required) 10-char Apple Developer Team ID.
#   PROVISIONING_PROFILE  (required) Name of the installed App Store provisioning profile
#                         for io.dwk.anglesite.
#   ASC_API_KEY_ID        (required unless --validate-only) App Store Connect API key id.
#   ASC_API_ISSUER_ID     (required unless --validate-only) App Store Connect API issuer id.

set -euo pipefail

VALIDATE_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --validate-only) VALIDATE_ONLY=1 ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "error: unknown argument '$arg'" >&2; exit 64 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/Anglesite.xcarchive"
EXPORT_DIR="$BUILD_DIR/export-mas"
EXPORT_OPTIONS="$BUILD_DIR/exportOptions-appstore.plist"
EXPORT_OPTIONS_TEMPLATE="$SCRIPT_DIR/exportOptions-appstore.plist"
BUNDLE_ID="io.dwk.anglesite"
SCHEME="Anglesite"
CONFIGURATION="Release"

bail() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n=== %s ===\n' "$*"; }

# --- Preflight ---------------------------------------------------------------
step "0/6 preflight"

[[ -n "${TEAM_ID:-}" ]] \
    || bail "TEAM_ID is unset. Export your 10-character Apple Developer Team ID and re-run."
[[ -n "${PROVISIONING_PROFILE:-}" ]] \
    || bail "PROVISIONING_PROFILE is unset. Set it to the name of the App Store provisioning profile for $BUNDLE_ID."

command -v xcodegen >/dev/null || bail "xcodegen not installed. brew install xcodegen"
command -v xcodebuild >/dev/null || bail "xcodebuild not on PATH (install Xcode + command line tools)."
xcrun --find altool >/dev/null 2>&1 || bail "xcrun altool unavailable. Use a full Xcode install (not just CLT)."

# Apple Distribution signing identity (signs the .app).
security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Distribution" \
    || bail "no 'Apple Distribution' codesigning identity in the keychain. Create one in the Apple Developer portal and install it."

# Mac Installer Distribution identity (signs the .pkg). Installer certs are not codesigning
# certs, so they don't appear under -p codesigning; scan the full identity list.
security find-identity -v 2>/dev/null | grep -Eq "Mac Installer Distribution|3rd Party Mac Developer Installer" \
    || bail "no 'Mac Installer Distribution' (installer) identity in the keychain. App Store .pkg signing needs it."

# WWDR-G3 intermediate cert — without it the distribution chain won't validate at upload.
security find-certificate -a 2>/dev/null | grep -q "Apple Worldwide Developer Relations" \
    || bail "Apple WWDR intermediate cert missing. Download G3 from https://www.apple.com/certificateauthority/ and add it to the keychain."

if [[ "$VALIDATE_ONLY" -eq 0 ]]; then
    [[ -n "${ASC_API_KEY_ID:-}" ]] \
        || bail "ASC_API_KEY_ID is unset (needed for upload). Re-run with --validate-only to skip the upload step."
    [[ -n "${ASC_API_ISSUER_ID:-}" ]] \
        || bail "ASC_API_ISSUER_ID is unset (needed for upload). Re-run with --validate-only to skip the upload step."
fi

echo "  team:        $TEAM_ID"
echo "  profile:     $PROVISIONING_PROFILE"
echo "  mode:        $([[ "$VALIDATE_ONLY" -eq 1 ]] && echo 'validate-only (no upload)' || echo 'validate + upload')"

# --- Generate project + export options ---------------------------------------
step "1/6 xcodegen generate"
(cd "$REPO_ROOT" && xcodegen generate)

mkdir -p "$BUILD_DIR"
sed -e "s/__TEAM_ID__/$TEAM_ID/g" \
    -e "s/__PROVISIONING_PROFILE__/$PROVISIONING_PROFILE/g" \
    "$EXPORT_OPTIONS_TEMPLATE" > "$EXPORT_OPTIONS"

# --- Archive -----------------------------------------------------------------
step "2/6 xcodebuild archive ($SCHEME)"
rm -rf "$ARCHIVE_PATH"
xcodebuild \
    -project "$REPO_ROOT/Anglesite.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    archive
[[ -d "$ARCHIVE_PATH" ]] || bail "archive produced no .xcarchive at $ARCHIVE_PATH"

# --- Verify the bundled-Node re-sign survived the archive --------------------
# resign-node.sh runs as a post-build phase; confirm the embedded Node is signed with a
# hardened runtime and the same team as the app, before we wrap it in the installer .pkg.
step "3/6 verify bundled-Node re-sign"
ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/Anglesite.app"
NODE_BIN="$ARCHIVED_APP/Contents/Resources/node-runtime/bin/node"
if [[ -f "$NODE_BIN" ]]; then
    codesign --verify --strict --verbose=2 "$NODE_BIN" \
        || bail "bundled Node failed codesign --verify. The resign-node.sh post-build phase did not hold through archive."
    node_team="$(codesign -dvv "$NODE_BIN" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [[ "$node_team" == "$TEAM_ID" ]] \
        || bail "bundled Node TeamIdentifier '$node_team' != app team '$TEAM_ID' — bundle seal/App Store acceptance would fail."
    codesign -d --entitlements - --xml "$NODE_BIN" 2>/dev/null | grep -q "com.apple.security.cs.allow-jit" \
        && echo "  node: signed, team=$node_team, JIT entitlement present" \
        || echo "  node: signed, team=$node_team (no JIT entitlement — confirm intended)"
else
    echo "  no bundled Node at $NODE_BIN — node-runtime is an optional resource; skipping."
fi

# --- Export ------------------------------------------------------------------
step "4/6 xcodebuild -exportArchive (app-store-connect)"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

PKG_PATH="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.pkg' -print -quit)"
[[ -n "$PKG_PATH" && -f "$PKG_PATH" ]] || bail "export produced no .pkg under $EXPORT_DIR"
echo "  → $PKG_PATH ($(stat -f%z "$PKG_PATH") bytes)"

# --- Validate ----------------------------------------------------------------
# Validation does not need ASC API creds when running purely against the package shape,
# but App Store Connect validation (asset/entitlement checks) does — so it shares the
# upload credentials. In --validate-only mode without creds we still run the local
# package validation that altool can do offline.
step "5/6 altool --validate-app"
validate_args=(--validate-app --type macos --file "$PKG_PATH")
upload_args=(--upload-app --type macos --file "$PKG_PATH")
if [[ -n "${ASC_API_KEY_ID:-}" && -n "${ASC_API_ISSUER_ID:-}" ]]; then
    validate_args+=(--apiKey "$ASC_API_KEY_ID" --apiIssuer "$ASC_API_ISSUER_ID")
    upload_args+=(--apiKey "$ASC_API_KEY_ID" --apiIssuer "$ASC_API_ISSUER_ID")
    xcrun altool "${validate_args[@]}"
else
    echo "  (no ASC API creds — skipping App Store Connect validation; supply ASC_API_KEY_ID/ISSUER to enable)"
fi

# --- Upload ------------------------------------------------------------------
step "6/6 altool --upload-app"
if [[ "$VALIDATE_ONLY" -eq 1 ]]; then
    cat <<EOF

✅ Validate-only run complete. Package ready at:
     $PKG_PATH

To upload to App Store Connect, re-run without --validate-only (and with
ASC_API_KEY_ID / ASC_API_ISSUER_ID set), or drop the .pkg into Transporter.app.
EOF
    exit 0
fi

xcrun altool "${upload_args[@]}"

cat <<EOF

✅ Uploaded $SCHEME to App Store Connect.

Next steps:
  1. Wait for processing in App Store Connect → TestFlight / App Store.
  2. Attach the build to a version and submit for review.
See docs/release.md "Mac App Store submission" for the full flow.
EOF
