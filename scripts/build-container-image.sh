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
#   ANGLESITE_PLUGIN_SRC plugin checkout (default: ../anglesite sibling, like copy-plugin.sh)
#
# Distribution (decision Q-D): the image is built once for linux/arm64 and pushed
# to a registry BY DIGEST. Apple Containerization pulls that exact digest; the
# Cloudflare substrate layers its sandbox init on top via container/Dockerfile.cloudflare
# (#61). Pinning by digest is what makes the two substrates reproducibly identical —
# see container/README.md.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CONTAINER_DIR="$REPO_ROOT/container"
VERSION_FILE="$SCRIPT_DIR/node-version.txt"

IMAGE_REPO="${IMAGE_REPO:-ghcr.io/anglesite/anglesite-devserver}"
IMAGE_TAG="${IMAGE_TAG:-dev}"
PLATFORM="linux/arm64"

PUSH=0
[[ "${1:-}" == "--push" ]] && PUSH=1

[[ -f "$VERSION_FILE" ]] || { echo "missing $VERSION_FILE" >&2; exit 1; }
NODE_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
[[ -n "$NODE_VERSION" ]] || { echo "$VERSION_FILE is empty" >&2; exit 1; }

# Resolve the plugin source the same way copy-plugin.sh does.
DEFAULT_SRC=$(cd "$REPO_ROOT/.." && pwd)/anglesite
SRC="${ANGLESITE_PLUGIN_SRC:-$DEFAULT_SRC}"
[[ -d "$SRC" ]] || { echo "plugin source not found at $SRC (set ANGLESITE_PLUGIN_SRC)" >&2; exit 1; }
[[ -f "$SRC/.claude-plugin/plugin.json" ]] || { echo "$SRC is not the Anglesite plugin (no .claude-plugin/plugin.json)" >&2; exit 1; }
[[ -f "$SRC/template/package.json" && -f "$SRC/template/package-lock.json" ]] \
    || { echo "template manifests missing under $SRC/template" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || { echo "docker not found on PATH" >&2; exit 1; }

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
    "$SRC/" "$CTX/plugin/"

# Template: manifests only. We bake the template's dependency closure, not its source.
mkdir -p "$CTX/template"
cp "$SRC/template/package.json" "$SRC/template/package-lock.json" "$CTX/template/"

# ---- Build --------------------------------------------------------------------
IMAGE_REF="${IMAGE_REPO}:${IMAGE_TAG}"
META="$CTX/metadata.json"
OUTPUT="--load"
[[ $PUSH -eq 1 ]] && OUTPUT="--push"

echo "==> Building $IMAGE_REF for $PLATFORM (Node v$NODE_VERSION)"
docker buildx build \
    --platform "$PLATFORM" \
    --build-arg "NODE_VERSION=$NODE_VERSION" \
    --tag "$IMAGE_REF" \
    --metadata-file "$META" \
    $OUTPUT \
    "$CTX"

DIGEST=$(awk -F'"' '/containerimage.digest/{print $4}' "$META" 2>/dev/null || true)

echo
echo "Built $IMAGE_REF (linux/arm64, Node v$NODE_VERSION)"
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
