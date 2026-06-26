# Anglesite local dev-server image (arm64 / Apple Silicon). Built and exported as an OCI layout by
# scripts/vendor-container-image.sh, then bundled into AnglesiteContainer. Bakes Node + git +
# the vsock→TCP bridge. The MCP sidecar is layered in by a later change (TODO(#69)); it is NOT
# baked here.

# Build the vsock bridge.
FROM --platform=linux/arm64 golang:1.22-bookworm AS bridge
WORKDIR /src
COPY vsock-bridge/ ./vsock-bridge/
RUN cd vsock-bridge && go mod tidy && CGO_ENABLED=0 GOARCH=arm64 go build -o /vsock-bridge .

# Pinned to linux/arm64 digest for reproducible vendoring. Re-bump periodically for base security updates.
FROM node:22-bookworm-slim@sha256:6db9be2ebb4bafb687a078ef5ba1b1dd256e8004d246a31fd210b6b848ab6be2
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=bridge /vsock-bridge /usr/local/bin/vsock-bridge
# The MCP sidecar + entrypoint are layered in by the build script from the app's bundled plugin.
WORKDIR /workspace
