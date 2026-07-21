#!/usr/bin/env bash
#
# Xcode Cloud post-clone hook (Apple auto-detects and runs any executable in ci_scripts/
# immediately after cloning the repo, before resolving package dependencies or opening the
# project — see https://developer.apple.com/documentation/xcode/writing-custom-build-scripts).
#
# Anglesite.xcodeproj is gitignored and generated from project.yml via XcodeGen (see
# CONTRIBUTING.md), so a fresh Xcode Cloud clone has no project file at all. This script
# regenerates it before Xcode Cloud tries to resolve the scheme it was configured to build.
#
# XcodeGen version/digest pinned to match the XCODEGEN_VERSION/XCODEGEN_SHA256 exact pin in
# .github/workflows/ci.yml — bump both together. (scripts/check-xcodeproj-sync.sh's
# MIN_XCODEGEN is a floor, not an exact pin, so it doesn't need to match this value bump for
# bump, but it should stay <= it.)
set -euo pipefail

XCODEGEN_VERSION="2.45.4"
XCODEGEN_SHA256="090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef"

# CI_PRIMARY_REPOSITORY_PATH is the clone of this repo (Xcode Cloud env var); fall back to
# this script's own location so it can also be run by hand for local testing.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$SCRIPT_DIR/.." && pwd)}"

echo "==> Installing XcodeGen ${XCODEGEN_VERSION}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

curl -fsSL "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip" \
    -o "$WORK_DIR/xcodegen.zip"
echo "${XCODEGEN_SHA256}  $WORK_DIR/xcodegen.zip" | shasum -a 256 --check
unzip -q "$WORK_DIR/xcodegen.zip" -d "$WORK_DIR/dist"

XCODEGEN_BIN="$WORK_DIR/dist/xcodegen/bin/xcodegen"
[[ -x "$XCODEGEN_BIN" ]] \
    || { echo "error: xcodegen binary not found at expected path after unzip — check zip layout" >&2; exit 1; }

echo "==> Generating Anglesite.xcodeproj from project.yml"
cd "$REPO_ROOT"
"$XCODEGEN_BIN" generate
