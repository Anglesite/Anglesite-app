#!/usr/bin/env bash
#
# Task 4b — build, entitle, and run the `anglesite-container-probe` CLI.
#
# `swift test`'s own runner (swiftpm-testing-helper) cannot carry
# `com.apple.security.virtualization` — Apple's toolchain is not ours to re-sign — so a bare
# `swift test` fails before `dialVsock` is ever reached for AnglesiteContainerLocalTests's live
# cases. This script builds `anglesite-container-probe` (a standalone executable that links
# AnglesiteContainer directly), code-signs the *actual built binary* with
# Resources/container-probe.entitlements, and execs it — giving the live vsock/boot gate a
# process that really is entitled.
#
# Usage:
#   scripts/run-container-probe.sh echo   # THE Task 4b decision gate (vsock round-trip)
#   scripts/run-container-probe.sh boot    # Task 5's gate (full boot + preview HTTP poll)
#
# On an ad-hoc-signing environment where the Virtualization entitlement still isn't honored at
# runtime (e.g. no provisioning profile trusts an ad-hoc identity for the restricted
# entitlement), retry with SIGN_IDENTITY set to a real Apple Development identity for the app's
# team, e.g.:
#   SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" scripts/run-container-probe.sh echo

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

SUBCOMMAND="${1:-}"
case "${SUBCOMMAND}" in
    echo|boot) ;;
    *)
        echo "usage: $(basename "$0") <echo|boot>" >&2
        exit 2
        ;;
esac

ENTITLEMENTS="${ROOT_DIR}/Resources/container-probe.entitlements"
[[ -f "${ENTITLEMENTS}" ]] || { echo "run-container-probe: missing ${ENTITLEMENTS}" >&2; exit 1; }

export ANGLESITE_CONTAINER_TESTS="${ANGLESITE_CONTAINER_TESTS:-1}"

echo "==> run-container-probe: building anglesite-container-probe (Debug)"
swift build --package-path "${ROOT_DIR}" --product anglesite-container-probe

BIN_PATH="$(swift build --package-path "${ROOT_DIR}" --product anglesite-container-probe --show-bin-path)/anglesite-container-probe"
[[ -x "${BIN_PATH}" ]] || { echo "run-container-probe: built binary not found at ${BIN_PATH}" >&2; exit 1; }

# Default to ad-hoc; the caller can override with a real Apple Development identity (team
# KH7H8Y25RT) if ad-hoc signing doesn't get the Virtualization entitlement honored at runtime.
IDENTITY="${SIGN_IDENTITY:--}"

echo "==> run-container-probe: signing ${BIN_PATH} with identity '${IDENTITY}' + ${ENTITLEMENTS}"
codesign --force --sign "${IDENTITY}" --entitlements "${ENTITLEMENTS}" "${BIN_PATH}"

echo "==> run-container-probe: running '${SUBCOMMAND}'"
exec "${BIN_PATH}" "${SUBCOMMAND}"
