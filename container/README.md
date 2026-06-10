# Anglesite dev-server container image

The **one OCI image, two substrates** that issue [#62](https://github.com/Anglesite/Anglesite-app/issues/62) calls for. The Astro dev server and the plugin's MCP server run **inside this Linux container**, never in the host app process, so the dev server behaves identically everywhere:

| Substrate | Platform | How it gets the image |
|---|---|---|
| **Apple Containerization** (local) | `Anglesite` DevID build · macOS 26+ · Apple Silicon | pulls the canonical image **by digest** |
| **Cloudflare Sandbox** (remote) | `AnglesiteMAS` · Intel · macOS < 26 · iOS | extends the canonical image via [`Dockerfile.cloudflare`](Dockerfile.cloudflare) (#61) |

This realizes the [design doc](../docs/specs/2026-05-30-cloudflare-sandbox-dev-server-design.md) §0 ("platform-split, one container image") and answers follow-up **Q-D** (image distribution).

## What's in the image

- **Node**, pinned to [`scripts/node-version.txt`](../scripts/node-version.txt) (passed as `NODE_VERSION` at build).
- **`git`** — Git is the source of truth (design §3.1 option A); the container clones the site on start, edits commit/push. No host-share, no embedded Node.
- **The Astro / site toolchain**, pre-installed from the plugin template's lockfile (`@opt/anglesite/baked`).
- **The plugin's MCP server runtime** — `server/*.mjs` plus its production deps, baked at `/opt/anglesite/plugin` (`ANGLESITE_MCP_ENTRY`). The plugin is the source of truth for the MCP server (`CLAUDE.md`).
- **`tini`** as PID 1 for signal/zombie reaping.

Built for **`linux/arm64`** (local Apple Silicon + Cloudflare).

## Pre-baked dependencies (skip `npm ci` on cold start)

Design decision **#5b**: cold starts must not pay for `npm ci`. At build time the template's full dependency closure is installed once, which:

1. **warms the npm cache** (`/opt/anglesite/npm-cache`) for any cloned site, and
2. keeps the resolved **`node_modules`** at `/opt/anglesite/baked`.

On start, [`hydrate.sh`](hydrate.sh) installs the cloned site's deps the fastest way available:

- lockfile **identical** to the baked template → hardlink the baked `node_modules` (**zero install** — the common case for template-derived sites);
- otherwise → `npm ci --prefer-offline` against the warm cache.

## Build

```sh
# Build + load locally (arm64). Reads Node version + plugin source automatically.
scripts/build-container-image.sh

# Build + push to the registry by digest, and print the digest to pin.
scripts/build-container-image.sh --push
```

Env overrides: `IMAGE_REPO` (default `ghcr.io/anglesite/anglesite-devserver`), `IMAGE_TAG` (default `dev`), `ANGLESITE_PLUGIN_SRC` (default `../anglesite`, same as `copy-plugin.sh`).

The script stages a clean build context (plugin runtime + template manifests + helper scripts), so the `Dockerfile` is **not** buildable on its own — build through the script.

## Runtime contract

The default `ENTRYPOINT` ([`entrypoint.sh`](entrypoint.sh)) hydrates then execs the CMD; substrates may override either:

| Variable | Purpose |
|---|---|
| `ANGLESITE_GIT_URL` | repo to clone into `$SITE_DIR` when it's empty |
| `ANGLESITE_GIT_REF` | branch/tag/sha to check out after clone |
| `SITE_DIR` | working tree (default `/workspace`) |
| `PORT` | Astro dev port (default `4321`) |
| `ANGLESITE_MCP_ENTRY` | path to the baked MCP server entry |

The default CMD ([`start-dev-server.sh`](start-dev-server.sh)) runs `astro dev` bound to `0.0.0.0`. The **network-reachable MCP server** starts here too once the plugin's HTTP/SSE transport (#63) and `MCPClient`'s HTTP transport (#64) land; until then the MCP runtime is baked in and started over stdio by the runtime layer.

## Distribution decision (Q-D)

**Build once, push by digest; both substrates consume the same digest.**

- The canonical image is built for `linux/arm64` and pushed to a registry (default GHCR). For reproducibility, pin the **base image by digest** and consume the **resulting image by digest** — not by floating tag.
- **Apple Containerization** pulls that exact digest locally — no second build, no drift.
- **Cloudflare Sandbox** can't run the canonical image entirely unmodified: the Sandbox SDK needs its standalone `/sandbox` init binary in the image. [`Dockerfile.cloudflare`](Dockerfile.cloudflare) `FROM`s the canonical image (by digest) and adds **only** that binary, so the toolchain layers stay byte-identical to what Apple Containerization runs. Cloudflare builds/pushes this thin wrapper to its own registry at `wrangler deploy`; the exact `/sandbox` source pin is finalized by the Cloudflare spike (#61).

This keeps the *behavior-defining* layers (Node, git, Astro toolchain, plugin MCP runtime, baked deps) identical across substrates while accommodating each substrate's init requirements.
