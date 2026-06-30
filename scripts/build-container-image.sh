#!/usr/bin/env bash
#
# Build the shared Anglesite dev-server OCI image (issue #62).
#
# ONE image, TWO substrates: Apple Containerization (local) and Cloudflare Sandbox
# (remote) run the SAME linux/arm64 image so the dev server behaves identically
# everywhere. Node is pinned to scripts/node-version.txt; git, the Astro/site
# toolchain, and the plugin's MCP server runtime are baked in; the template's
# dependency closure is pre-installed so cold starts skip npm ci (design §5b).
#
# Usage:
#   scripts/build-container-image.sh            # build + load locally (arm64)
#   scripts/build-container-image.sh --push     # build + push to $IMAGE_REPO, print digest
#
# Env overrides:
#   IMAGE_REPO            registry repo (default: ghcr.io/anglesite/anglesite-devserver)
#   IMAGE_TAG            human tag    (default: dev)
#   PLATFORM             build arch   (default: linux/arm64). Set linux/amd64 for the
#                        Cloudflare substrate (CF Containers are amd64-only), or a
#                        comma list "linux/amd64,linux/arm64" for a multi-arch manifest.
#   ANGLESITE_PLUGIN_SRC plugin checkout (default: ../anglesite sibling, like copy-plugin.sh)
#
# Distribution (decision Q-D): the canonical image is pushed to a registry BY DIGEST.
# Apple Containerization runs arm64 (local, Apple Silicon); Cloudflare Containers run
# amd64 (remote) — so "one image, two substrates" is one Dockerfile built per-arch (or
# multi-arch) and pinned by digest. The Cloudflare substrate layers its sandbox init on
# top via container/Dockerfile.cloudflare (#61). See container/README.md.
#
# NOTE: a multi-arch (comma) PLATFORM only works with --push — buildx cannot --load a
# multi-platform manifest into the local Docker image store. Asking for both errors out.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CONTAINER_DIR="$REPO_ROOT/container"
VERSION_FILE="$SCRIPT_DIR/node-version.txt"

IMAGE_REPO="${IMAGE_REPO:-ghcr.io/anglesite/anglesite-devserver}"
IMAGE_TAG="${IMAGE_TAG:-dev}"
PLATFORM="${PLATFORM:-linux/arm64}"

PUSH=0
[[ "${1:-}" == "--push" ]] && PUSH=1

# buildx can only --load a single-platform image into the local store. A multi-arch
# (comma-separated) PLATFORM must be pushed straight to the registry.
if [[ "$PLATFORM" == *,* && $PUSH -eq 0 ]]; then
    echo "PLATFORM='$PLATFORM' is multi-arch; buildx cannot --load it locally." >&2
    echo "Re-run with --push (multi-arch goes straight to ${IMAGE_REPO}), or set a single PLATFORM." >&2
    exit 1
fi

[[ -f "$VERSION_FILE" ]] || { echo "missing $VERSION_FILE" >&2; exit 1; }
NODE_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
[[ -n "$NODE_VERSION" ]] || { echo "$VERSION_FILE is empty" >&2; exit 1; }

# Resolve the plugin source the same way copy-plugin.sh does.
DEFAULT_SRC=$(cd "$REPO_ROOT/.." && pwd)/anglesite
SRC="${ANGLESITE_PLUGIN_SRC:-$DEFAULT_SRC}"
[[ -d "$SRC" ]] || { echo "plugin source not found at $SRC (set ANGLESITE_PLUGIN_SRC)" >&2; exit 1; }
[[ -f "$SRC/.claude-plugin/plugin.json" ]] || { echo "$SRC is not the Anglesite plugin (no .claude-plugin/plugin.json)" >&2; exit 1; }
TEMPLATE_DIR="$REPO_ROOT/Resources/Template"
[[ -f "$TEMPLATE_DIR/package.json" ]] \
    || { echo "template manifests missing under $TEMPLATE_DIR" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || { echo "docker not found on PATH" >&2; exit 1; }

# Use a docker-container buildx builder explicitly so multi-platform builds don't depend on the
# developer's globally active builder. Do not call `docker buildx use`; that would leave global
# Docker state changed after this script exits.
if ! docker buildx inspect anglesite-oci >/dev/null 2>&1; then
    docker buildx create --name anglesite-oci --driver docker-container
fi

# ---- Stage a clean build context ----------------------------------------------
CTX=$(mktemp -d)
trap 'rm -rf "$CTX"' EXIT

echo "==> Staging build context"
cp "$CONTAINER_DIR/Dockerfile" "$CONTAINER_DIR/.dockerignore" "$CTX/"
cp "$CONTAINER_DIR/entrypoint.sh" "$CONTAINER_DIR/hydrate.sh" "$CONTAINER_DIR/start-dev-server.sh" "$CTX/"

# Plugin runtime: server + manifests + lockfile. node_modules/.git and other
# heavy/private dirs are excluded — production deps are installed inside the image.
mkdir -p "$CTX/plugin"
rsync -a \
    --exclude='node_modules/' --exclude='.git/' --exclude='.github/' \
    --exclude='.worktrees/' --exclude='.serena/' --exclude='.playwright-mcp/' \
    --exclude='.claude/' --exclude='dist/' --exclude='build/' \
    --exclude='tests/' --exclude='test/' --exclude='docs/' \
    --exclude='*.log' --exclude='.DS_Store' \
    --exclude='template/' \
    "$SRC/" "$CTX/plugin/"

# Template: manifests only. We bake the template's dependency closure, not its source.
mkdir -p "$CTX/template"
cp "$TEMPLATE_DIR/package.json" "$CTX/template/"
[[ -f "$TEMPLATE_DIR/package-lock.json" ]] && cp "$TEMPLATE_DIR/package-lock.json" "$CTX/template/"

# ---- Build --------------------------------------------------------------------
IMAGE_REF="${IMAGE_REPO}:${IMAGE_TAG}"
META="$CTX/metadata.json"
OUTPUT="--load"
[[ $PUSH -eq 1 ]] && OUTPUT="--push"

BUILD_ARGS=(
    --builder anglesite-oci
    --platform "$PLATFORM"
    --build-arg "NODE_VERSION=$NODE_VERSION"
    --tag "$IMAGE_REF"
    --metadata-file "$META"
    "$OUTPUT"
)
# Provenance attestations make a --push emit an OCI *index* manifest that both Apple
# `container` and Cloudflare image pull can reject as an unexpected multi-arch image.
# Strip them on push only; a local --load build keeps its (harmless) default metadata.
[[ $PUSH -eq 1 ]] && BUILD_ARGS+=(--provenance=false)

echo "==> Building $IMAGE_REF for $PLATFORM (Node v$NODE_VERSION)"
docker buildx build "${BUILD_ARGS[@]}" "$CTX"

# Informational only: the digest lets you pin both substrates to one image. The
# `|| true` keeps a missing/absent metadata file from aborting the run under
# `set -e` — callers that need to gate on the digest should check it themselves.
DIGEST=$(awk -F'"' '/containerimage\.digest/{print $4}' "$META" 2>/dev/null || true)

echo
echo "Built $IMAGE_REF ($PLATFORM, Node v$NODE_VERSION)"
if [[ -n "$DIGEST" ]]; then
    echo "Digest: $DIGEST"
    echo
    echo "Pin BOTH substrates to this digest for reproducibility:"
    echo "  ${IMAGE_REPO}@${DIGEST}"
fi
if [[ $PUSH -eq 0 ]]; then
    echo
    echo "Loaded into the local Docker image store. Re-run with --push to publish to $IMAGE_REPO."
fi
