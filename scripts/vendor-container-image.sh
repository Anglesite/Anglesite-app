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
# Fail fast, before staging work: no point copying the sidecar/template if the CLI is missing.
ensure_container_cli
CTX="$ROOT/Containers/anglesite-dev"
OUT="$ROOT/Resources/container-image"

# ---------------------------------------------------------------------------
# Stage the MCP sidecar source into the image build context.
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

# ---------------------------------------------------------------------------
# Stage the website template's dependency manifests + the hydrate script into
# the build context, so the image can bake the template's full node_modules
# (design §5b, same pattern as container/Dockerfile). hydrate.sh is shared
# with the Cloudflare image — container/hydrate.sh is the single source.
# ---------------------------------------------------------------------------
TEMPLATE_STAGE="$CTX/template"
echo "Staging template manifests from $ROOT/Resources/Template → $TEMPLATE_STAGE"
rm -rf "$TEMPLATE_STAGE"
mkdir -p "$TEMPLATE_STAGE"
cp "$ROOT/Resources/Template/package.json" "$TEMPLATE_STAGE/"
cp "$ROOT/Resources/Template/package-lock.json" "$TEMPLATE_STAGE/"
cp "$ROOT/container/hydrate.sh" "$CTX/hydrate.sh"

# Clean up the staged sidecar + template + hydrate script on exit (success or
# failure) so they don't accumulate in the build context. These are gitignored.
cleanup_sidecar() { rm -rf "$SIDECAR_STAGE" "$TEMPLATE_STAGE" "$CTX/hydrate.sh"; }
trap cleanup_sidecar EXIT

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
container build \
    --os linux --arch arm64 \
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
