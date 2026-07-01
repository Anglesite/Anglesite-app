# Apple Containerization Image

This directory is the **active macOS container image source** for Anglesite.

`scripts/vendor-container-image.sh` builds `Containers/anglesite-dev/Dockerfile`
with Docker/buildx, exports the result as an OCI layout into
`Resources/container-image/`, and the `AnglesiteContainer` Swift target bundles
that inert Linux root filesystem as app data.

Docker is only the image builder here. At runtime on macOS, Anglesite boots the
vendored OCI image with Apple's Containerization framework via
`ContainerizationControl`; it does not run Docker.

Directory map:

| Path | Purpose |
|---|---|
| `Containers/anglesite-dev/` | Active Apple Containerization image context: Node, git, MCP sidecar, and the guest vsock-to-TCP bridge. |
| `../container/` | Cloudflare Sandbox / shared-image staging path. It is not the app-bundled macOS image source. |

