# Docker-free app image vendoring via Apple `container` CLI

**Date:** 2026-07-08
**Status:** Approved design
**Scope decision:** App-build scripts only (`scripts/vendor-container-image.sh`, `scripts/vendor-container-kernel.sh`). The Cloudflare/remote pipeline (`scripts/build-container-image.sh`) stays on Docker — it is a registry-push pipeline for the remote substrate, not part of building the macOS app.

## Problem

Building the macOS app currently requires Docker, but only as an image builder:

1. `scripts/vendor-container-image.sh` builds `Containers/anglesite-dev/Dockerfile` through a
   `docker-container` buildx builder (`anglesite-oci`) — created solely because the default
   docker driver cannot emit `--output type=oci`.
2. `scripts/vendor-container-kernel.sh` uses a `FROM`-only Dockerfile buildx build as a hack to
   pull `ghcr.io/apple/containerization/vminit` and re-export it as an OCI layout.

The app runtime never uses Docker — it boots the vendored OCI layout with Apple's
Containerization framework. Apple's `container` CLI (v1.1.0+) builds Dockerfiles natively,
defaults to OCI output (`-o type=oci,dest=…`), and pulls/saves images as OCI tars — so the
builder and the runtime can share one OCI implementation and Docker drops out of the app build
entirely.

## Design

### 1. `scripts/vendor-container-image.sh`

- Delete the `docker buildx inspect/create anglesite-oci` block.
- Replace the build step with:

  ```sh
  container build --os linux --arch arm64 \
      -t anglesite-dev:latest \
      -o "type=oci,dest=${ARCHIVE}" \
      "$CTX"
  ```

- Everything else is unchanged: sidecar/template staging, `.gitkeep`-preserving wipe of
  `Resources/container-image/`, untar of the OCI archive, layout verification
  (`oci-layout`, `index.json`, `blobs/sha256`).

### 2. `scripts/vendor-container-kernel.sh`

- Kernel half: untouched (already Docker-free — `curl` + `tar`).
- Initfs half: replace the `FROM`-only Dockerfile hack with the direct form:

  ```sh
  container image pull --platform linux/arm64 "$VMINIT_IMAGE"
  container image save --platform linux/arm64 -o "$INITFS_ARCHIVE" "$VMINIT_IMAGE"
  ```

  then untar into `Resources/container-initfs/` as today. The existing structural validation
  and skopeo fallback stay.

### 3. Preflight (both scripts)

A small shared preflight (sourced snippet or duplicated ~6-liner):

- `command -v container` — if missing, fail with an actionable error pointing at
  <https://github.com/apple/container/releases>.
- `container system start` — run unconditionally before building; it is idempotent and no-ops
  when the API server is already up. `container build` fails without it.

### 4. `BundledImage.imageReference` alignment

buildx writes `io.containerd.image.name: docker.io/library/anglesite-dev:latest` into the
layout's `index.json`, and `Sources/AnglesiteContainer/BundledImage.swift` hardcodes that exact
string for `ImageStore.get(reference:)`. Apple `container` may normalize the tag differently.

After the first real build, inspect the emitted `index.json`; if the name annotation differs,
update `BundledImage.imageReference` and its explanatory comment in the same PR. The
`loadOrGet` single-image fallback in `ContainerizationControl.swift` means a mismatch degrades
gracefully (a one-image layout still boots), but the constant must match so `get(reference:)`
hits on re-imports.

### 5. Error handling

- Missing CLI → actionable install error (see preflight).
- Build failure → `container build` output streams through unmodified (logs are sacred).
- Malformed export → caught by the existing layout validation in both scripts.

### 6. Documentation updates

- Header comments in both vendor scripts (they currently say "Requires Docker").
- `Containers/README.md`.
- `docs/build-plan.md` — the line saying `vendor-container-image.sh` "builds it with
  Docker/buildx".
- `CLAUDE.md` — the two mentions of Docker/buildx as the image-build tool.
- New requirement statement everywhere: Apple `container` CLI (≥ 1.1) on an Apple-Silicon Mac;
  Docker is only needed for the separate Cloudflare/remote pipeline
  (`scripts/build-container-image.sh`).

## Out of scope

- `scripts/build-container-image.sh` (Cloudflare/remote pipeline): amd64/multi-arch manifests,
  `--provenance` handling, and registry pushes stay on Docker/buildx.
- No changes to `Containers/anglesite-dev/Dockerfile` — Apple `container` consumes it as-is.
- No runtime (Swift) behavior changes other than the possible `imageReference` constant bump.

## Verification

1. Run `scripts/vendor-container-image.sh` and `scripts/vendor-container-kernel.sh` for real;
   confirm both OCI layouts pass their structural checks.
2. Inspect `Resources/container-image/index.json` for the name annotation; align
   `BundledImage.imageReference` if needed.
3. Boot check via `scripts/run-container-probe.sh` (`swift test` cannot boot VMs — the probe
   is the entitled path).
4. `swift test` for the `AnglesiteContainer` unit suites.
