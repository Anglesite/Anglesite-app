# Anglesite local dev-server image (arm64 / Apple Silicon). Built and exported as an OCI layout by
# scripts/vendor-container-image.sh, then bundled into AnglesiteContainer. Bakes Node + the app's
# MCP sidecar + the vsock→TCP bridge so first run needs no in-guest install.

# Build the vsock bridge.
FROM --platform=linux/arm64 golang:1.22-bookworm AS bridge
WORKDIR /src
COPY vsock-bridge/ ./vsock-bridge/
RUN cd vsock-bridge && go mod tidy && CGO_ENABLED=0 GOARCH=arm64 go build -o /vsock-bridge .

FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=bridge /vsock-bridge /usr/local/bin/vsock-bridge
# MCP sidecar: staged by scripts/vendor-container-image.sh from the plugin's server/ dir.
# npm ci runs on linux/arm64 → pulls @img/sharp-linux-arm64 (the native prebuilt) from the
# lockfile. --omit=dev drops devDependencies. We intentionally do NOT pass --omit=optional
# because @img/sharp-linux-arm64 is marked optional in the lockfile (platform-specific prebuilt);
# npm's platform-cpu/os filters already skip macOS-only optionals like fsevents on linux/arm64.
COPY mcp-sidecar/ /usr/local/lib/anglesite-mcp/
RUN cd /usr/local/lib/anglesite-mcp && npm ci --omit=dev
WORKDIR /workspace
