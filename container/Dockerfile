# syntax=docker/dockerfile:1
#
# Canonical Anglesite dev-server image — issue #62 (design doc Q-D).
#
# ONE image, TWO substrates. The Astro dev server and the plugin's MCP server
# run inside this Linux container, never in the host app process, so the dev
# server behaves identically everywhere:
#
#   • Apple Containerization (local, DevID Macs)  — pulls this image by digest.
#   • Cloudflare Sandbox     (remote, MAS / iOS)  — see container/Dockerfile.cloudflare.
#
# Built for linux/arm64 (local Apple Silicon + Cloudflare). Node is pinned to
# scripts/node-version.txt and passed in as NODE_VERSION by
# scripts/build-container-image.sh.

ARG NODE_VERSION=24.15.0
FROM node:${NODE_VERSION}-bookworm-slim

# git: Git is the source of truth — the container clones the site on start
#      (design §3.1 option A). No host-share, no embedded Node.
# tini: PID 1 that reaps the long-lived dev server's children and forwards signals.
# ca-certificates: HTTPS git clone + npm registry.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates tini \
 && rm -rf /var/lib/apt/lists/*

ENV ANGLESITE_HOME=/opt/anglesite \
    NPM_CONFIG_CACHE=/opt/anglesite/npm-cache \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false \
    SITE_DIR=/workspace \
    PORT=4321

# ---- Plugin MCP server runtime ------------------------------------------------
# The plugin is the source of truth for the MCP server (CLAUDE.md). Bake its
# runtime — server/*.mjs plus the production dependency closure
# (@modelcontextprotocol/sdk, sharp, and the SDK's hoisted zod) — so the runtime
# substrates can start it with no network install. Deps are installed against the
# committed lockfile before the source is copied so this layer caches well.
COPY plugin/package.json plugin/package-lock.json ${ANGLESITE_HOME}/plugin/
RUN cd ${ANGLESITE_HOME}/plugin \
 && ( npm ci --omit=dev \
      || { echo "WARN: plugin lockfile out of sync — falling back to npm install" >&2; \
           npm install --omit=dev; } )
COPY plugin/ ${ANGLESITE_HOME}/plugin/
ENV ANGLESITE_MCP_ENTRY=${ANGLESITE_HOME}/plugin/server/index.mjs

# ---- Pre-baked site toolchain (skip npm ci on cold start; design §5b) ---------
# Install the template's full dependency closure once, at build time. This warms
# the npm cache for any cloned site AND keeps the resolved node_modules so a site
# whose lockfile matches the template reuses it with zero install (hydrate.sh).
# `npm ci` is preferred (reproducible, and it's what hydrate.sh's zero-install
# fast path compares against). If the template's committed lockfile has drifted
# out of sync with its package.json, fall back to `npm install` with a loud
# warning rather than failing the image — sites then take hydrate.sh's
# warm-cache `npm ci` path instead of the zero-install hardlink.
COPY template/package.json template/package-lock.json ${ANGLESITE_HOME}/baked/
RUN cd ${ANGLESITE_HOME}/baked \
 && ( npm ci \
      || { echo "WARN: template lockfile out of sync — falling back to npm install" >&2; \
           npm install; } )

# ---- Hydration + start helpers ------------------------------------------------
COPY entrypoint.sh hydrate.sh start-dev-server.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/hydrate.sh \
             /usr/local/bin/start-dev-server.sh

WORKDIR /workspace
EXPOSE 4321

# tini as PID 1; entrypoint hydrates the repo + deps, then execs the CMD.
# Substrates may override CMD or drive their own start sequence — this is a
# sensible, override-friendly default.
ENTRYPOINT ["/usr/bin/tini", "--", "entrypoint.sh"]
CMD ["start-dev-server.sh"]
