#!/usr/bin/env bash
#
# Default entrypoint for the Anglesite dev-server image (issue #62).
#
# Hydrates the site (Git is the source of truth — design §3.1 option A): clones
# $ANGLESITE_GIT_URL into $SITE_DIR when the dir is empty, installs deps via the
# pre-baked toolchain (hydrate.sh), then execs the CMD (default: start-dev-server.sh).
#
# The runtime substrates (LocalContainerSiteRuntime / RemoteSandboxSiteRuntime,
# issues #69 / #66) may override the CMD or run their own start sequence; this
# entrypoint stays an override-friendly default that "just works" when exec'd bare.

set -euo pipefail

SITE_DIR="${SITE_DIR:-/workspace}"
mkdir -p "$SITE_DIR"
cd "$SITE_DIR"

if [ -n "${ANGLESITE_GIT_URL:-}" ] && [ -z "$(ls -A "$SITE_DIR" 2>/dev/null)" ]; then
    echo "==> Cloning ${ANGLESITE_GIT_URL} (ref: ${ANGLESITE_GIT_REF:-default})"
    git clone "${ANGLESITE_GIT_URL}" "$SITE_DIR"
    if [ -n "${ANGLESITE_GIT_REF:-}" ]; then
        git -C "$SITE_DIR" checkout "${ANGLESITE_GIT_REF}"
    fi
fi

# Install the site's npm dependencies, reusing the pre-baked toolchain when possible.
if [ -f "$SITE_DIR/package.json" ]; then
    hydrate.sh "$SITE_DIR"
fi

exec "$@"
