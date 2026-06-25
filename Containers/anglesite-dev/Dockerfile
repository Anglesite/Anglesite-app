# Anglesite local dev-server image (arm64 / Apple Silicon). Built and exported as an OCI layout by
# scripts/vendor-container-image.sh, then bundled into AnglesiteContainer. Bakes Node + the app's
# MCP sidecar + the vsock→TCP bridge so first run needs no in-guest install.
FROM --platform=linux/arm64 node:22-bookworm-slim

# git is needed to clone the site's Source/ repo at boot; ca-certificates for npm/outbound.
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Build the vsock bridge.
FROM --platform=linux/arm64 golang:1.22-bookworm AS bridge
WORKDIR /src
COPY vsock-bridge/ ./vsock-bridge/
RUN cd vsock-bridge && go mod tidy && CGO_ENABLED=0 GOARCH=arm64 go build -o /vsock-bridge .

FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=bridge /vsock-bridge /usr/local/bin/vsock-bridge
# The MCP sidecar + entrypoint are layered in by the build script from the app's bundled plugin.
WORKDIR /workspace
