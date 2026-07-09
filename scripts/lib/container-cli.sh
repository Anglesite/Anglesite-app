#!/usr/bin/env bash
# Shared preflight for scripts that build/pull images with the Apple `container` CLI
# (https://github.com/apple/container). Source this file, then call ensure_container_cli.
#
# NOT used by scripts/build-container-image.sh — the Cloudflare/remote pipeline
# intentionally stays on Docker/buildx (amd64 + registry-push concerns).

ensure_container_cli() {
    if ! command -v container >/dev/null 2>&1; then
        echo "ERROR: Apple 'container' CLI not found on PATH." >&2
        echo "       Install it from https://github.com/apple/container/releases and re-run." >&2
        exit 1
    fi
    # Idempotent: no-ops when the API server is already up. `container build` and
    # `container image pull` fail without a running server, so always start it here.
    container system start
}
