#!/usr/bin/env bash
# Build VendoredGitSpike, vendor a non-Apple (Homebrew-built) git binary + its two dylib deps
# into a real .app bundle, ad-hoc sign it with app-sandbox entitlements, and run it via `open` —
# the same methodology #640 itself used to get a real sandbox container attached.
#
# The probe binary runs the identical init/add/commit/rev-parse sequence through BOTH the
# vendored git and Apple's system /usr/bin/git, in the same sandboxed process, for a direct
# side-by-side comparison.
set -euo pipefail

cd "$(dirname "$0")/.."
SPIKE_DIR="$PWD"
RESULTS_DIR="$SPIKE_DIR/results"
VENDOR_DIR="$SPIKE_DIR/vendor"
BUNDLE_ID="io.dwk.anglesite.spikes.vendoredgit"
mkdir -p "$RESULTS_DIR"

BREW_GIT_PREFIX="$(brew --prefix git 2>/dev/null || true)"
if [[ -z "$BREW_GIT_PREFIX" || ! -x "$BREW_GIT_PREFIX/bin/git" ]]; then
    echo "FATAL: Homebrew git not found. Run 'brew install git' first (this spike needs a" >&2
    echo "non-Apple git build — the point is testing a binary NOT gated by Xcode CLT licensing)." >&2
    exit 1
fi
echo "==> using vendor source: $BREW_GIT_PREFIX/bin/git ($("$BREW_GIT_PREFIX/bin/git" --version))"

echo "==> swift build"
swift build -c release --arch arm64

BIN="$(swift build -c release --arch arm64 --show-bin-path)/VendoredGitSpike"
[[ -x "$BIN" ]] || { echo "FATAL: binary not at $BIN — did the build succeed?" >&2; exit 1; }

echo
echo "==> assembling vendored git payload in $VENDOR_DIR"
rm -rf "$VENDOR_DIR"
mkdir -p "$VENDOR_DIR/bin" "$VENDOR_DIR/lib" "$VENDOR_DIR/libexec/git-core"

cp "$BREW_GIT_PREFIX/bin/git" "$VENDOR_DIR/bin/git"
PCRE2_DYLIB="$(otool -L "$BREW_GIT_PREFIX/bin/git" | awk '/libpcre2/{print $1}')"
INTL_DYLIB="$(otool -L "$BREW_GIT_PREFIX/bin/git" | awk '/libintl/{print $1}')"
cp "$PCRE2_DYLIB" "$VENDOR_DIR/lib/$(basename "$PCRE2_DYLIB")"
cp "$INTL_DYLIB" "$VENDOR_DIR/lib/$(basename "$INTL_DYLIB")"
# libintl itself depends on libiconv, which is a stable /usr/lib system dylib on every macOS
# version — no need to vendor it.

chmod u+w "$VENDOR_DIR/bin/git" "$VENDOR_DIR/lib/"*.dylib

echo "==> rewriting dylib load paths to be self-contained (@executable_path-relative)"
install_name_tool -change "$PCRE2_DYLIB" "@executable_path/../lib/$(basename "$PCRE2_DYLIB")" "$VENDOR_DIR/bin/git"
install_name_tool -change "$INTL_DYLIB" "@executable_path/../lib/$(basename "$INTL_DYLIB")" "$VENDOR_DIR/bin/git"
install_name_tool -id "@executable_path/../lib/$(basename "$PCRE2_DYLIB")" "$VENDOR_DIR/lib/$(basename "$PCRE2_DYLIB")"
install_name_tool -id "@executable_path/../lib/$(basename "$INTL_DYLIB")" "$VENDOR_DIR/lib/$(basename "$INTL_DYLIB")"

echo "==> re-signing vendored payload (install_name_tool invalidates existing signatures)"
codesign --force --sign - "$VENDOR_DIR/lib/"*.dylib
codesign --force --sign - "$VENDOR_DIR/bin/git"

# git's builtins (init/add/commit/rev-parse) don't need libexec/git-core dispatch, but a
# GIT_EXEC_PATH that resolves to something real avoids startup warnings — symlink farm back to
# the one vendored binary, exactly matching Homebrew's own layout shape.
for cmd in git git-init git-add git-commit git-rev-parse; do
    ln -sf ../../bin/git "$VENDOR_DIR/libexec/git-core/$cmd"
done

echo "==> verifying vendored binary now only references system + self-contained libs"
otool -L "$VENDOR_DIR/bin/git"

echo
echo "==> building .app bundle"
APP="$RESULTS_DIR/VendoredGitSpike.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VendoredGitSpike"
cp "$SPIKE_DIR/Entitlements/Info.plist" "$APP/Contents/Info.plist"
cp -R "$VENDOR_DIR" "$APP/Contents/Resources/git-vendor"

echo "==> ad-hoc signing the whole bundle with sandbox entitlements"
codesign --force --deep --sign - --entitlements "$SPIKE_DIR/Entitlements/sandboxed.plist" "$APP"
codesign -d --entitlements - "$APP" 2>&1 | grep -A2 app-sandbox || true

RESULT_JSON="$HOME/Library/Containers/$BUNDLE_ID/Data/tmp/vendoredgitspike-result.json"
rm -f "$RESULT_JSON"

echo
echo "==> launching sandboxed .app via 'open' (mirrors #640's own repro methodology)"
open -W -a "$APP"

echo "==> polling for result file at $RESULT_JSON"
for _ in $(seq 1 20); do
    [[ -f "$RESULT_JSON" ]] && break
    sleep 0.5
done

if [[ -f "$RESULT_JSON" ]]; then
    cp "$RESULT_JSON" "$RESULTS_DIR/sandboxed-result.json"
    echo
    echo "==> sandboxed result:"
    cat "$RESULTS_DIR/sandboxed-result.json"
else
    echo "FATAL: no result file appeared at $RESULT_JSON after 10s." >&2
    exit 1
fi

echo
echo "Saved to $RESULTS_DIR/sandboxed-result.json"
