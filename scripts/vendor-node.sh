#!/usr/bin/env bash
#
# Phase 1 — vendor a macOS Node.js runtime into Resources/node-runtime/.
#
# Reads the pinned version from scripts/node-version.txt. Downloads the arm64
# tarball from nodejs.org, verifies SHA256 against the project's
# SHASUMS256.txt, optionally GPG-verifies SHASUMS (warns if Node maintainer
# keys aren't imported), then extracts the distribution to
# Resources/node-runtime/. arm64-only: the app targets macOS 27+, which runs
# exclusively on Apple silicon (#106).
#
# Idempotent: a no-op if the destination already contains the pinned version.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VERSION_FILE="$SCRIPT_DIR/node-version.txt"
DEST="$REPO_ROOT/Resources/node-runtime"

[[ -f "$VERSION_FILE" ]] || { echo "missing $VERSION_FILE" >&2; exit 1; }
NODE_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
[[ -n "$NODE_VERSION" ]] || { echo "$VERSION_FILE is empty" >&2; exit 1; }

DIST_URL="https://nodejs.org/dist/v${NODE_VERSION}"
ARM64_TARBALL="node-v${NODE_VERSION}-darwin-arm64.tar.xz"

if [[ -x "$DEST/bin/node" ]]; then
    current=$("$DEST/bin/node" --version 2>/dev/null || echo "")
    if [[ "$current" == "v${NODE_VERSION}" ]]; then
        if file "$DEST/bin/node" | grep -q "universal binary"; then
            echo "Existing $DEST/bin/node is a pre-#106 universal binary. Re-vendoring as arm64-only."
        else
            echo "Node ${current} already vendored at $DEST. Skipping."
            exit 0
        fi
    fi
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading Node v${NODE_VERSION} (arm64) from nodejs.org"
curl -fL --progress-bar -o "$TMP/$ARM64_TARBALL" "$DIST_URL/$ARM64_TARBALL"
curl -fLs -o "$TMP/SHASUMS256.txt" "$DIST_URL/SHASUMS256.txt"

echo "==> Verifying SHA256 checksum"
(
    cd "$TMP"
    expected=$(awk -v f="$ARM64_TARBALL" '$2 == f { print $1 }' SHASUMS256.txt)
    [[ -n "$expected" ]] || { echo "no checksum entry for $ARM64_TARBALL" >&2; exit 1; }
    actual=$(shasum -a 256 "$ARM64_TARBALL" | awk '{ print $1 }')
    if [[ "$expected" != "$actual" ]]; then
        echo "SHA256 mismatch for $ARM64_TARBALL" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        exit 1
    fi
    echo "  ok  $ARM64_TARBALL"
)

echo "==> Verifying GPG signature on SHASUMS256.txt (best effort)"
if command -v gpg >/dev/null && curl -fLs -o "$TMP/SHASUMS256.txt.sig" "$DIST_URL/SHASUMS256.txt.sig"; then
    if gpg --verify "$TMP/SHASUMS256.txt.sig" "$TMP/SHASUMS256.txt" 2>/dev/null; then
        echo "  ok  signature valid"
    else
        echo "  WARN: GPG verify failed — Node maintainer keys probably not imported."
        echo "        See https://github.com/nodejs/release-keys for import instructions."
        echo "        Proceeding on SHA256 alone."
    fi
else
    echo "  WARN: gpg or .sig not available; skipping signature verification."
fi

echo "==> Extracting arm64 distribution to $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
tar --strip-components=1 -xf "$TMP/$ARM64_TARBALL" -C "$DEST"
chmod +x "$DEST/bin/node"

echo "==> Verifying arm64 binary"
file "$DEST/bin/node" | grep -q "arm64" || { echo "vendored node is not an arm64 binary" >&2; exit 1; }
"$DEST/bin/node" --version | grep -q "^v${NODE_VERSION}$" || { echo "vendored node reports unexpected version" >&2; exit 1; }

echo
echo "Vendored Node v${NODE_VERSION} (arm64) at $DEST/bin/node"
file "$DEST/bin/node"
