#!/usr/bin/env bash
#
# Phase 1 — vendor a universal macOS Node.js runtime into Resources/node-runtime/.
#
# Reads the pinned version from scripts/node-version.txt. Downloads both arm64
# and x64 tarballs from nodejs.org, verifies SHA256 against the project's
# SHASUMS256.txt, optionally GPG-verifies SHASUMS (warns if Node maintainer
# keys aren't imported), extracts the arm64 distribution, then `lipo`s the
# two `node` binaries into a single universal Mach-O at
# Resources/node-runtime/bin/node.
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
X64_TARBALL="node-v${NODE_VERSION}-darwin-x64.tar.xz"

if [[ -x "$DEST/bin/node" ]]; then
    current=$("$DEST/bin/node" --version 2>/dev/null || echo "")
    if [[ "$current" == "v${NODE_VERSION}" ]]; then
        echo "Node ${current} already vendored at $DEST. Skipping."
        exit 0
    fi
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading Node v${NODE_VERSION} (arm64 + x64) from nodejs.org"
curl -fL --progress-bar -o "$TMP/$ARM64_TARBALL" "$DIST_URL/$ARM64_TARBALL"
curl -fL --progress-bar -o "$TMP/$X64_TARBALL"   "$DIST_URL/$X64_TARBALL"
curl -fLs -o "$TMP/SHASUMS256.txt" "$DIST_URL/SHASUMS256.txt"

echo "==> Verifying SHA256 checksums"
(
    cd "$TMP"
    for tarball in "$ARM64_TARBALL" "$X64_TARBALL"; do
        expected=$(awk -v f="$tarball" '$2 == f { print $1 }' SHASUMS256.txt)
        [[ -n "$expected" ]] || { echo "no checksum entry for $tarball" >&2; exit 1; }
        actual=$(shasum -a 256 "$tarball" | awk '{ print $1 }')
        if [[ "$expected" != "$actual" ]]; then
            echo "SHA256 mismatch for $tarball" >&2
            echo "  expected: $expected" >&2
            echo "  actual:   $actual" >&2
            exit 1
        fi
        echo "  ok  $tarball"
    done
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

echo "==> Extracting x64 node binary for lipo merge"
mkdir -p "$TMP/x64"
tar --strip-components=1 -xf "$TMP/$X64_TARBALL" -C "$TMP/x64" "node-v${NODE_VERSION}-darwin-x64/bin/node"

echo "==> Creating universal binary at $DEST/bin/node"
lipo -create "$DEST/bin/node" "$TMP/x64/bin/node" -output "$TMP/node-universal"
mv "$TMP/node-universal" "$DEST/bin/node"
chmod +x "$DEST/bin/node"

echo "==> Verifying universal binary"
file "$DEST/bin/node" | grep -q "universal binary" || { echo "lipo did not produce a universal binary" >&2; exit 1; }
"$DEST/bin/node" --version | grep -q "^v${NODE_VERSION}$" || { echo "vendored node reports unexpected version" >&2; exit 1; }

echo
echo "Vendored Node v${NODE_VERSION} (universal arm64+x64) at $DEST/bin/node"
file "$DEST/bin/node"
