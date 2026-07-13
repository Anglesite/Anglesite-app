#!/usr/bin/env bash
# Build the active macOS Apple Containerization image and export it as an OCI layout into
# Resources/container-image/.
#
# Apple's `container` CLI is the image builder. At runtime Anglesite imports this OCI layout
# and boots it with Apple's Containerization framework — builder and runtime share the same
# OCI implementation. Docker is not used anywhere on this path.
#
# Produces a gitignored, bundled app resource. Requires the Apple `container` CLI (≥ 1.1,
# https://github.com/apple/container) on an Apple-Silicon Mac.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/container-cli.sh"
source "$ROOT/scripts/lib/stage-dev-image-context.sh"
# Fail fast, before staging work: no point copying the sidecar/template if the CLI is missing.
ensure_container_cli
CTX="$ROOT/Containers/anglesite-dev"
OUT="$ROOT/Resources/container-image"

stage_dev_image_context "$CTX"

echo "Building anglesite-dev:latest (linux/arm64)…"

echo "Exporting OCI layout → $OUT"
# Wipe any stale layout contents but preserve the committed .gitkeep placeholder so
# git does not report a deletion (the gitignore rules exclude everything else in the dir).
find "$OUT" -mindepth 1 -not -name '.gitkeep' -delete 2>/dev/null || true
mkdir -p "$OUT"

# Build into the CLI's local image store, then export with `container image save`, which emits
# a spec-compliant OCI image layout (index.json + oci-layout + blobs/sha256/) as a tar archive.
# Two steps instead of `container build --output type=oci,dest=…` because that flag is broken in
# container CLI 1.1.0 (the build completes, then the CLI errors "image.tar doesn't exist" —
# the tarball never lands at dest; reproduced with a trivial FROM-alpine build). Side benefit:
# the store keeps anglesite-dev:latest between runs, so rebuilds are incremental — the same role
# the old docker-container buildx builder's cache played.
ARCHIVE="$OUT/image.tar"
# --build-arg TARGETARCH is explicit rather than relying on the builder to auto-inject it
# (unlike BuildKit, container CLI 1.1.0's docs don't confirm it sets platform ARGs
# automatically) — the Dockerfile's per-arch base-image stage selection needs it either way.
container build \
    --os linux --arch arm64 \
    --build-arg TARGETARCH=arm64 \
    --tag anglesite-dev:latest \
    "$CTX"
container image save --platform linux/arm64 --output "$ARCHIVE" anglesite-dev:latest

tar -xf "$ARCHIVE" -C "$OUT"
rm -f "$ARCHIVE"

# Verify the layout is valid before reporting success.
for f in oci-layout index.json blobs/sha256; do
    [[ -e "$OUT/$f" ]] || { echo "ERROR: OCI layout missing $f" >&2; exit 1; }
done

echo "Done. Resources/container-image/ now holds an OCI layout."
echo "Contents:"
ls -la "$OUT"
