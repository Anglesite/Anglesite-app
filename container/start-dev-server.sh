#!/usr/bin/env bash
#
# Default CMD: start the Astro dev server bound to all interfaces so the substrate
# can reach it (local container IP, or a Cloudflare exposed port). HMR rides the
# same connection (design §2).
#
# The network-reachable MCP server starts here too once the sidecar grows an
# HTTP/SSE transport (#63) and MCPClient grows the matching HTTP transport (#64).
# Until then the MCP runtime is baked in (ANGLESITE_MCP_ENTRY) and started by the
# runtime layer over stdio. See container/README.md.

set -euo pipefail

SITE_DIR="${SITE_DIR:-/workspace}"
PORT="${PORT:-4321}"
cd "$SITE_DIR"

echo "==> astro dev on 0.0.0.0:${PORT}"
exec npm run dev -- --host 0.0.0.0 --port "${PORT}"
