#!/usr/bin/env bash
# Build the Anglesite local dev-server image with podman, tagged for PodmanContainerControl
# (Sources/AnglesiteCore/Platform/PodmanContainerControl.swift) — the Linux SiteRuntime substrate.
#
# Unlike scripts/vendor-container-image.sh (Apple `container` CLI, macOS-only, arm64-only —
# Apple Containerization only runs on Apple Silicon), this script builds NATIVELY for whatever
# architecture the host running it is. No cross-arch emulation is needed: a Linux amd64 machine
# produces an amd64 image, a Linux arm64 machine (or an Apple Silicon Mac with podman machine)
# produces an arm64 image. This is what closes the "linux/amd64" gap in the vendored image
# pipeline (design doc §7) — most Linux desktops are amd64, and there was previously no script
# at all that provisioned the podman-consumed image for either architecture.
#
# The image is tagged into the local podman store only — it is not saved/exported anywhere,
# unlike the macOS path's OCI-layout bundling, since PodmanContainerControl reads directly
# from the local store (`podman build`/`podman load`, not a registry pull — see its doc comment).
#
# Requires podman (rootless is fine) on PATH.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/stage-dev-image-context.sh"

command -v podman >/dev/null 2>&1 || { echo "ERROR: podman not found on PATH." >&2; exit 1; }

CTX="$ROOT/Containers/anglesite-dev"
IMAGE_TAG="localhost/anglesite-dev:latest"

stage_dev_image_context "$CTX"

# podman's `--arch` defaults to the host's native architecture; TARGETARCH is passed explicitly
# as a build-arg (matching vendor-container-image.sh) since it drives the Dockerfile's per-arch
# base-image stage selection rather than relying on podman to inject it automatically.
HOST_ARCH="$(podman info --format '{{.Host.Arch}}')"
case "$HOST_ARCH" in
    arm64|amd64) ;;
    *)
        echo "ERROR: unsupported host arch '$HOST_ARCH' (Dockerfile only pins arm64/amd64 bases)." >&2
        exit 1
        ;;
esac

echo "Building $IMAGE_TAG (linux/$HOST_ARCH, native)…"
podman build \
    --build-arg "TARGETARCH=$HOST_ARCH" \
    --tag "$IMAGE_TAG" \
    "$CTX"

echo "Done. $IMAGE_TAG is in the local podman store:"
podman images "$IMAGE_TAG"
