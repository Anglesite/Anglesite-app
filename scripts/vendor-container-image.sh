#!/usr/bin/env bash
# Build the arm64 Anglesite dev image and export it as an OCI layout into Resources/container-image/.
# Mirrors scripts/vendor-node.sh: produces a gitignored, bundled app resource. Requires Docker (or
# a compatible buildx) with linux/arm64 support, run on an Apple-Silicon Mac.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTX="$ROOT/Containers/anglesite-dev"
OUT="$ROOT/Resources/container-image"

# ---------------------------------------------------------------------------
# Stage the MCP sidecar source into the Docker build context.
# The plugin source is outside the build context (sibling repo), so we copy
# it in before building and clean up after. Mirror scripts/copy-plugin.sh's
# resolution: honor $ANGLESITE_PLUGIN_SRC, default to ../anglesite (sibling
# under the same parent dir as this repo).
# ---------------------------------------------------------------------------
DEFAULT_PLUGIN_SRC="$(cd "$ROOT/.." && pwd)/anglesite"
PLUGIN_SRC="${ANGLESITE_PLUGIN_SRC:-$DEFAULT_PLUGIN_SRC}"

if [[ ! -d "$PLUGIN_SRC" ]]; then
    echo "ERROR: plugin source not found at $PLUGIN_SRC" >&2
    echo "       Set ANGLESITE_PLUGIN_SRC or clone github.com/Anglesite/anglesite as a sibling." >&2
    exit 1
fi
if [[ ! -f "$PLUGIN_SRC/.claude-plugin/plugin.json" ]]; then
    echo "ERROR: $PLUGIN_SRC does not look like the Anglesite plugin (no .claude-plugin/plugin.json)" >&2
    exit 1
fi

SIDECAR_STAGE="$CTX/mcp-sidecar"
echo "Staging MCP sidecar from $PLUGIN_SRC → $SIDECAR_STAGE"
rm -rf "$SIDECAR_STAGE"
mkdir -p "$SIDECAR_STAGE"

# Copy the plugin's server/ directory + package manifests (no node_modules, no .git).
rsync -a --delete \
    --exclude='node_modules/' \
    --exclude='.git/' \
    "$PLUGIN_SRC/server/" "$SIDECAR_STAGE/server/"
cp "$PLUGIN_SRC/package.json" "$SIDECAR_STAGE/"
cp "$PLUGIN_SRC/package-lock.json" "$SIDECAR_STAGE/"

echo "Sidecar staged: $(ls "$SIDECAR_STAGE")"

# Clean up the staged sidecar on exit (success or failure) so it doesn't
# accumulate in the build context. The directory itself is gitignored.
cleanup_sidecar() { rm -rf "$SIDECAR_STAGE"; }
trap cleanup_sidecar EXIT

echo "Building anglesite-dev:latest (linux/arm64)…"

# The brief's original export path used `docker save` + `skopeo copy` to produce an OCI layout.
# skopeo is not a standard install and is absent on many dev Macs. Instead we use a buildx
# docker-container driver builder which supports `--output type=oci` natively — the default
# `docker` driver does not support OCI output, so a separate builder is required. This avoids
# the skopeo dependency entirely and produces the same OCI layout on disk.
#
# Guard: create the builder only if it doesn't already exist (idempotent).
# Note: we do NOT call `docker buildx use` — it would mutate the developer's global active
# builder and persist after this script exits. The `--builder anglesite-oci` flag on the
# build command below is sufficient and side-effect-free.
if ! docker buildx inspect anglesite-oci >/dev/null 2>&1; then
    docker buildx create --name anglesite-oci --driver docker-container
fi

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
    --output "type=oci,name=anglesite-dev:latest,dest=${ARCHIVE}" \
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
