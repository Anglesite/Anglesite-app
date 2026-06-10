# Throwaway spike image (#61): canonical Anglesite dev-server image
#   + the Cloudflare Sandbox `/sandbox` init binary (so the Worker can drive it)
#   + cloudflared (for the per-session quick tunnel — design §3.3 / #61).
#
# Mirrors container/Dockerfile.cloudflare but adds cloudflared, which the canonical
# image doesn't carry. The behaviour-defining layers (Node, git, Astro toolchain,
# baked deps, plugin MCP runtime) come from the canonical image unchanged.
#
# Prereq: the canonical image must be pushed to a registry wrangler can pull at
# deploy time. Build + push it first:
#     IMAGE_TAG=dev scripts/build-container-image.sh --push   # prints the digest
# then set CANONICAL_IMAGE below to that digest (pin by digest, not tag).
#
# ARCH NOTE (spike finding): Cloudflare Containers run linux/amd64; the canonical
# image is built linux/arm64 for Apple Silicon. Build the canonical image
# multi-arch (or amd64) for the Cloudflare substrate, or this FROM will fail to
# run on CF. Confirm + record during the live run.

ARG CANONICAL_IMAGE=ghcr.io/anglesite/anglesite-devserver:dev
ARG SANDBOX_IMAGE=docker.io/cloudflare/sandbox:0.12.1

FROM ${SANDBOX_IMAGE} AS sandbox

FROM ${CANONICAL_IMAGE}

# Cloudflare Sandbox init lives at /container-server/sandbox (NOT /sandbox — validated
# by inspecting cloudflare/sandbox:0.12.1 during this spike). It starts the Sandbox HTTP
# API then spawns CMD as a child. Copy the whole dir in case the binary has siblings.
COPY --from=sandbox /container-server /container-server

# cloudflared (for the per-session quick tunnel) is already bundled in the sandbox image —
# reuse it instead of downloading, which also keeps the arch consistent with /sandbox.
COPY --from=sandbox /usr/local/bin/cloudflared /usr/local/bin/cloudflared

EXPOSE 4321
ENTRYPOINT ["/container-server/sandbox"]
CMD ["start-dev-server.sh"]
