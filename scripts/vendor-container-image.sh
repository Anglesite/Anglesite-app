#!/usr/bin/env bash
# Build the arm64 Anglesite dev image and export it as an OCI layout into Resources/container-image/.
# Mirrors scripts/vendor-node.sh: produces a gitignored, bundled app resource. Requires Docker (or
# a compatible buildx) with linux/arm64 support, run on an Apple-Silicon Mac.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTX="$ROOT/Containers/anglesite-dev"
OUT="$ROOT/Resources/container-image"

echo "Building anglesite-dev:latest (linux/arm64)…"

# The brief's original export path used `docker save` + `skopeo copy` to produce an OCI layout.
# skopeo is not a standard install and is absent on many dev Macs. Instead we use a buildx
# docker-container driver builder which supports `--output type=oci` natively — the default
# `docker` driver does not support OCI output, so a separate builder is required. This avoids
# the skopeo dependency entirely and produces the same OCI layout on disk.
#
# Guard: create the builder only if it doesn't already exist (idempotent).
if ! docker buildx inspect anglesite-oci >/dev/null 2>&1; then
    docker buildx create --name anglesite-oci --driver docker-container
fi
docker buildx use anglesite-oci

echo "Exporting OCI layout → $OUT"
# Wipe any stale layout contents but preserve the committed .gitkeep placeholder so
# git does not report a deletion (the gitignore rules exclude everything else in the dir).
find "$OUT" -mindepth 1 -not -name '.gitkeep' -delete 2>/dev/null || true
mkdir -p "$OUT"

# Build for linux/arm64 and emit an OCI archive (tar) directly into a temp file, then untar it
# into the layout directory. `--output type=oci,dest=...` emits a spec-compliant OCI image layout
# (index.json + oci-layout + blobs/sha256/) as a tar archive. We untar and remove the archive.
ARCHIVE="$OUT/image.tar"
docker buildx build \
    --platform linux/arm64 \
    --output "type=oci,dest=${ARCHIVE}" \
    --builder anglesite-oci \
    "$CTX"

tar -xf "$ARCHIVE" -C "$OUT"
rm -f "$ARCHIVE"

# Verify the layout is valid before reporting success.
for f in oci-layout index.json blobs/sha256; do
    [[ -e "$OUT/$f" ]] || { echo "ERROR: OCI layout missing $f" >&2; exit 1; }
done

echo "Done. Resources/container-image/ now holds an OCI layout."
echo "Contents:"
ls -la "$OUT"
