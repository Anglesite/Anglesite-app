#!/usr/bin/env bash
#
# Build-time guard for the vendored container boot artifacts.
#
# `Resources/container-{image,kernel,initfs}/` are gitignored and populated by
# scripts/vendor-container-image.sh (image) and scripts/vendor-container-kernel.sh
# (kernel + initfs). They ship into the app via SwiftPM `.copy()` resources on
# AnglesiteContainer, so an unvendored tree (fresh clone, new worktree, git clean)
# still BUILDS fine — the app only fails at runtime, when preview reports
# "imageLayoutNotProvisioned; kernelNotProvisioned; initfsNotProvisioned"
# (BundledImage.swift). This script surfaces that gap at build time instead.
#
# The checks mirror BundledImage.swift's provisioning markers exactly — the dirs
# always exist (each keeps a committed .gitkeep so the `.copy()` rule never
# breaks), so presence of the real artifact files is what "provisioned" means:
#   container-image/index.json    (OCI layout — vendor-container-image.sh)
#   container-kernel/vmlinux      (kernel binary — vendor-container-kernel.sh)
#   container-initfs/index.json   (vminit OCI layout — vendor-container-kernel.sh)
#
# Policy: Debug builds WARN (Xcode issue-navigator warnings, build continues) —
# a fresh worktree must stay buildable for work that never boots a container.
# Release builds FAIL — an archive without boot artifacts ships an app whose
# local-container preview can never work, and nothing downstream would catch it.
# Set ANGLESITE_ALLOW_UNPROVISIONED_CONTAINER=1 to downgrade a Release failure
# to a warning (e.g. exercising the Release configuration without vendoring).
#
# Lines prefixed `warning:` / `error:` are parsed by Xcode into real build issues.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
RESOURCES="$REPO_ROOT/Resources"

# Per-artifact runtime overrides (BundledImage honors these at runtime, so a dev
# running against external artifacts shouldn't be nagged about unvendored dirs).
missing=()

if [[ -z "${ANGLESITE_CONTAINER_IMAGE:-}" && ! -f "$RESOURCES/container-image/index.json" ]]; then
    missing+=("Resources/container-image is unvendored (no index.json) — run scripts/vendor-container-image.sh")
fi
if [[ -z "${ANGLESITE_CONTAINER_KERNEL:-}" && ! -f "$RESOURCES/container-kernel/vmlinux" ]]; then
    missing+=("Resources/container-kernel is unvendored (no vmlinux) — run scripts/vendor-container-kernel.sh")
fi
if [[ -z "${ANGLESITE_CONTAINER_INITFS:-}" && ! -f "$RESOURCES/container-initfs/index.json" ]]; then
    missing+=("Resources/container-initfs is unvendored (no index.json) — run scripts/vendor-container-kernel.sh")
fi

if [[ ${#missing[@]} -eq 0 ]]; then
    echo "==> Container boot artifacts provisioned — OK"
    exit 0
fi

# Release archives must not ship without boot artifacts; everything else warns.
severity="warning"
if [[ "${CONFIGURATION:-Debug}" == "Release" && "${ANGLESITE_ALLOW_UNPROVISIONED_CONTAINER:-0}" != "1" ]]; then
    severity="error"
fi

for m in "${missing[@]}"; do
    echo "$severity: $m" >&2
done
echo "$severity: local-container preview will fail at runtime with 'NotProvisioned' until the vendor scripts above are run (see BundledImage.swift)." >&2

if [[ "$severity" == "error" ]]; then
    echo "       To build Release anyway (NOT for distribution), set ANGLESITE_ALLOW_UNPROVISIONED_CONTAINER=1." >&2
    exit 1
fi
exit 0
