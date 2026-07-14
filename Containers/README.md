# Apple Containerization Image

This directory is the **active macOS container image source** for Anglesite.

`scripts/vendor-container-image.sh` builds `Containers/anglesite-dev/Dockerfile`
with Apple's `container` CLI, exports the result as an OCI layout into
`Resources/container-image/`, and the `AnglesiteContainer` Swift target bundles
that inert Linux root filesystem as app data.

Building the app needs no Docker: the Apple `container` CLI (≥ 1.1) is the image
builder, and at runtime Anglesite boots the vendored OCI image with Apple's
Containerization framework via `ContainerizationControl`. Docker remains only in
the separate Cloudflare/remote pipeline (`scripts/build-container-image.sh`).

Directory map:

| Path | Purpose |
|---|---|
| `Containers/anglesite-dev/` | Active Apple Containerization image context: Node, git, MCP sidecar, and the guest vsock-to-TCP bridge. |
| `../container/` | Cloudflare Sandbox / shared-image staging path. It is not the app-bundled macOS image source. |

