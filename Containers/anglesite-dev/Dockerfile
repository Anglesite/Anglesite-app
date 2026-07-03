# Anglesite local dev-server image (arm64 / Apple Silicon). Built and exported as an OCI layout by
# scripts/vendor-container-image.sh, then bundled into AnglesiteContainer. Bakes Node + git + socat
# (the vsock<->TCP bridge) + the app's MCP sidecar (the plugin's server/, npm ci'd for linux-arm64 so
# sharp's native binary is correct) so a fresh container needs no in-guest install.

# Pinned to linux/arm64 digest for reproducible vendoring. Re-bump periodically for base security updates.
FROM node:22-bookworm-slim@sha256:6db9be2ebb4bafb687a078ef5ba1b1dd256e8004d246a31fd210b6b848ab6be2
# socat is the guest-side vsock<->TCP bridge: the host reaches astro/mcp (guest-local TCP) by
# dialing AF_VSOCK ports that socat forwards to 127.0.0.1 (no vmnet on the sandboxed host, #60).
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates socat \
    && rm -rf /var/lib/apt/lists/*
# MCP sidecar: staged by scripts/vendor-container-image.sh from the plugin's server/ dir.
# npm ci runs on linux/arm64 → pulls @img/sharp-linux-arm64 (the native prebuilt) from the
# lockfile. --omit=dev drops devDependencies. We intentionally do NOT pass --omit=optional
# because @img/sharp-linux-arm64 is marked optional in the lockfile (platform-specific prebuilt);
# npm's platform-cpu/os filters already skip macOS-only optionals like fsevents on linux/arm64.
COPY mcp-sidecar/ /usr/local/lib/anglesite-mcp/
# Playwright is an unused optionalDependency of the plugin. We keep `npm ci` (reproducible; lock-exact)
# and cannot pass --omit=optional because @img/sharp-linux-arm64 is also optional (platform prebuilt).
# ENV prevents playwright's postinstall from downloading ~300 MB of browsers; rm strips the pkg dirs.
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
RUN cd /usr/local/lib/anglesite-mcp \
    && npm ci --omit=dev \
    && rm -rf node_modules/playwright node_modules/playwright-core node_modules/.cache/ms-playwright

# ---- Pre-baked site toolchain (skip cold npm install on boot; design §5b) ----
# Install the template's full dependency closure once, at image-build time. This keeps the
# resolved node_modules so a cloned site whose lockfile matches the template reuses it with
# zero install (anglesite-hydrate), AND leaves npm's cache (/root/.npm) in the layer so a
# drifted-lockfile site's `npm ci --prefer-offline` mostly avoids the network. Full closure
# (no --omit=dev): astro dev/check need devDependencies (tsx, @astrojs/check, typescript).
ENV ANGLESITE_HOME=/opt/anglesite
COPY template/package.json template/package-lock.json ${ANGLESITE_HOME}/baked/
RUN cd ${ANGLESITE_HOME}/baked \
    && ( npm ci \
         || { echo "WARN: template lockfile out of sync — falling back to npm install" >&2; \
              npm install; } )
COPY hydrate.sh /usr/local/bin/anglesite-hydrate
RUN chmod +x /usr/local/bin/anglesite-hydrate

WORKDIR /workspace
