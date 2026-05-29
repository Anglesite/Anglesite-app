#!/usr/bin/env bash
#
# Task N — re-sign the bundled Node runtime for the sandboxed Mac App Store build.
#
# Re-signs every Mach-O under node-runtime/ with the app's signing identity, hardened
# runtime, and Resources/node-runtime.entitlements (app-sandbox / inherit / JIT). Without
# this the embedded V8 OOMs at launch under the MAS app's hardened runtime, and the binary's
# team wouldn't match the app (breaking the bundle seal / App Store acceptance).
#
# Runs as a post-build phase on the AnglesiteMAS target (after resources are copied into the
# .app, before Xcode's implicit final code-sign seals the bundle). Also callable standalone
# from the release pipeline.
#
# Usage:
#   resign-node.sh [NODE_DIR] [ENTITLEMENTS]
# Defaults (in an Xcode build phase):
#   NODE_DIR     = $CODESIGNING_FOLDER_PATH/Contents/Resources/node-runtime
#   ENTITLEMENTS = $SRCROOT/Resources/node-runtime.entitlements
#   IDENTITY     = $EXPANDED_CODE_SIGN_IDENTITY (the identity Xcode resolved for the app),
#                  falling back to ad-hoc ("-") when unsigned.

set -euo pipefail

NODE_DIR="${1:-${CODESIGNING_FOLDER_PATH:-}/Contents/Resources/node-runtime}"
ENTITLEMENTS="${2:-${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/Resources/node-runtime.entitlements}"

if [[ -z "${NODE_DIR}" || ! -d "${NODE_DIR}" ]]; then
    echo "==> resign-node: no node-runtime at '${NODE_DIR}' — skipping (optional resource)."
    exit 0
fi
[[ -f "${ENTITLEMENTS}" ]] || { echo "resign-node: entitlements not found at ${ENTITLEMENTS}" >&2; exit 1; }

# Match the app's identity so the bundled binary's team matches the app bundle. Ad-hoc Debug
# builds resolve EXPANDED_CODE_SIGN_IDENTITY to "-", which is exactly what we re-sign with.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[[ -n "${IDENTITY}" ]] || IDENTITY="-"

# Secure timestamp for real (Distribution) Release signing; none for ad-hoc / Debug.
if [[ "${IDENTITY}" != "-" && "${CONFIGURATION:-Debug}" == "Release" ]]; then
    TIMESTAMP_ARG="--timestamp"
else
    TIMESTAMP_ARG="--timestamp=none"
fi

echo "==> resign-node: signing Mach-O under ${NODE_DIR} with identity '${IDENTITY}'"

signed=0
# Narrow to executables and shared-object extensions, then confirm Mach-O via `file`. A vanilla
# Node dist is just bin/node; the broader scan covers any future .dylib/.node addons.
while IFS= read -r -d '' candidate; do
    if file -b "${candidate}" | grep -q "Mach-O"; then
        codesign --force \
            --sign "${IDENTITY}" \
            --options runtime \
            --entitlements "${ENTITLEMENTS}" \
            ${TIMESTAMP_ARG} \
            "${candidate}"
        echo "    signed  ${candidate#"${NODE_DIR}"/}"
        signed=$((signed + 1))
    fi
done < <(find "${NODE_DIR}" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.node' -o -name '*.so' \) -print0)

if [[ "${signed}" -eq 0 ]]; then
    echo "resign-node: no Mach-O binaries found under ${NODE_DIR}" >&2
    exit 1
fi

echo "==> resign-node: re-signed ${signed} Mach-O binar$([[ ${signed} -eq 1 ]] && echo y || echo ies)."
