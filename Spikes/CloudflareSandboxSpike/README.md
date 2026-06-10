# Cloudflare Sandbox spike (#61)

Throwaway Worker that runs the **shared Anglesite dev-server image** (#62) inside a
[Cloudflare Sandbox](https://developers.cloudflare.com/sandbox/) to prove the *remote*
substrate end-to-end and produce real numbers for the design doc. **No app changes**;
this lives under `Spikes/` and is deleted once its findings land in
[`docs/specs/2026-06-10-cloudflare-sandbox-spike-notes.md`](../../docs/specs/2026-06-10-cloudflare-sandbox-spike-notes.md).

The real consumer is `RemoteSandboxSiteRuntime` (#66); this only validates the substrate.

## What it does

`src/index.ts` exposes routes that drive one sandbox:

| Route | Does |
|---|---|
| `POST /start?repo=&ref=` | clone the site → `hydrate.sh` (baked-deps fast path) → `astro dev` → poll ready → `exposePort`. Returns **per-phase timings**. |
| `POST /tunnel` | start a `cloudflared` quick tunnel to the dev port → `*.trycloudflare.com` URL (no wildcard DNS, WS/HMR works). |
| `POST /deploy` | run `pre-deploy-check` + `wrangler deploy` **in-container** (the security hook must run where the files are). |
| `GET /status` · `GET /logs?id=` · `POST /destroy` | inspect / tear down. |

## Prerequisites (yours — this is a live exercise)

1. **Cloudflare account with Workers Paid + Containers/Sandbox** enabled. Confirm with
   `npx wrangler whoami` and that Containers are available on the account.
2. **Docker** (to build the image locally; `docker info` must succeed).
3. A **registry wrangler can pull** the canonical image from (GHCR by default).
4. For `exposePort` preview URLs: a **custom domain with wildcard DNS** on the account
   (`.workers.dev` does NOT support the `*-sandbox-<id>.<domain>` subdomains). If you
   don't have one, use `POST /tunnel` instead — that's the path #61 actually calls for.

## Run it

```sh
# 0. Build + push the canonical image.
#    ⚠️ scripts/build-container-image.sh is HARDCODED to linux/arm64 today. Cloudflare
#    Containers run linux/amd64, so the script needs an amd64 / multi-arch build before
#    this deploys to CF (see ARCH NOTE below — this is a spike finding/follow-up). For now,
#    to get an amd64 image, edit PLATFORM in the script (or `docker buildx build --platform
#    linux/amd64 ...` by hand against the staged context).
IMAGE_TAG=spike scripts/build-container-image.sh --push   # arm64 today; prints the digest
#    → note the printed digest; set CANONICAL_IMAGE in ./Dockerfile to pin it.

# 1. Install + deploy the spike Worker (builds ./Dockerfile = canonical + /sandbox + cloudflared).
cd Spikes/CloudflareSandboxSpike
npm install
npx wrangler deploy

# 1b. Set the shared secret that gates every code-execution route (REQUIRED — the routes
#     run arbitrary commands in the container; a deployed Worker is public).
export SPIKE_SECRET=$(openssl rand -hex 24)
echo "$SPIKE_SECRET" | npx wrangler secret put SPIKE_SECRET
AUTH=(-H "Authorization: Bearer $SPIKE_SECRET")
BASE="https://anglesite-sandbox-spike.<your-subdomain>.workers.dev"

# 2. Cold start: clone + hydrate + astro dev. Records phase timings.
curl "${AUTH[@]}" -X POST "$BASE/start?repo=https://github.com/Anglesite/<a-real-site>.git&ref=main"

# 3a. Preview via tunnel (no DNS needed):
curl "${AUTH[@]}" -X POST "$BASE/tunnel"
#    → open the returned *.trycloudflare.com URL in a desktop browser.

# 3b. OR preview via exposePort (needs the custom domain): the URL is in /start's response.

# 4. HMR check: with the preview open, edit a file in-container and watch the browser update:
curl "${AUTH[@]}" "$BASE/logs?id=<devProcessId>"   # confirm astro is watching
#    (edit via a follow-up exec route, or git push + re-clone; see the findings doc)

# 5. In-container deploy (CF token for the deploy passed separately from the auth secret):
curl "${AUTH[@]}" -H "x-cf-token: <cf-deploy-token>" -X POST "$BASE/deploy"

# 6. Tear down:
curl "${AUTH[@]}" -X POST "$BASE/destroy"
```

> **Security:** every route except `/` runs code in the container, so all are gated behind
> `Authorization: Bearer $SPIKE_SECRET` (fail-closed if the secret is unset) and `repo`/`ref`
> are allowlist-validated before they touch a shell. Don't remove these even for a throwaway —
> a deployed Worker is reachable by anyone who learns the URL.

`npx wrangler tail` streams Worker logs while you poke the routes.

## Local validation (no Cloudflare account)

You can confirm the **image assembles** without deploying — this is what the spike
author ran first:

```sh
# Build the canonical image locally (arm64 on Apple Silicon):
IMAGE_TAG=spike scripts/build-container-image.sh
# Build the spike image on top (adds /container-server/sandbox + cloudflared from the
# sandbox image). NOTE: cloudflare/sandbox is amd64-only, so an arm64 build warns
# "InvalidBaseImagePlatform" and the copied binaries won't *run* on arm64 — but it
# proves the layers assemble. For a runnable image, build the canonical image amd64 first.
docker build -t anglesite-sandbox-spike:local \
  --build-arg CANONICAL_IMAGE=ghcr.io/anglesite/anglesite-devserver:spike \
  Spikes/CloudflareSandboxSpike
# Smoke the canonical image's dev server locally (clone + hydrate + astro dev):
docker run --rm -p 4321:4321 \
  -e ANGLESITE_GIT_URL=https://github.com/Anglesite/<a-real-site>.git \
  ghcr.io/anglesite/anglesite-devserver:spike
# → open http://localhost:4321
```

## ⚠️ ARCH NOTE — likely the spike's first real finding

Cloudflare Containers run **linux/amd64**; `scripts/build-container-image.sh` builds
**linux/arm64** (Apple Silicon / Apple Containerization). The "one image, two substrates"
goal (container/README.md) needs the canonical image built **multi-arch** (`linux/amd64,linux/arm64`)
or a per-substrate arch. Build the canonical image for amd64 before deploying here, and
record the multi-arch decision in the findings doc (feeds Q-D image distribution).

## Notes / gotchas baked into the scaffold

- The Sandbox init entrypoint (`/container-server/sandbox`) **bypasses** the image's
  `entrypoint.sh`, so the Worker drives `git clone` + `hydrate.sh` explicitly (this is also how
  #66 will work).
- `@cloudflare/sandbox` (npm) and `docker.io/cloudflare/sandbox` (image) **must be the same
  version** — pinned to `0.12.1` here and in `container/Dockerfile.cloudflare`.
- `instance_type` is `"standard"`; if cold start OOMs or is slow, that's a finding — record it.
