/**
 * Per-site Cloudflare Worker entry point.
 *
 * Composes @dwk/* social endpoints behind the site's static assets. This file is
 * generated/managed by Anglesite — manual edits are preserved between scaffolds but
 * the composition block is regenerated when features change.
 *
 * Static assets are served by the [assets] binding in wrangler.toml; this Worker
 * handles only the social endpoint paths. When no social features are enabled, this
 * file is not referenced (wrangler.toml has no `main` entry and deploys static-only).
 */

// Placeholder — V-2.1 (#353) will wire the actual @dwk/* imports here.
// The composition pattern follows @dwk/workers' documented model:
//
//   import { createIndieAuth } from "@dwk/indieauth";
//   import { createWebmention } from "@dwk/webmention";
//
//   const indieauth = createIndieAuth({ baseUrl });
//   const webmention = createWebmention({ baseUrl });
//
//   export default {
//     async fetch(request, env, ctx) {
//       const url = new URL(request.url);
//       if (url.pathname.startsWith("/.well-known/indieauth"))
//         return indieauth.fetch(request, env, ctx);
//       if (url.pathname.startsWith("/webmention"))
//         return webmention.fetch(request, env, ctx);
//       return env.ASSETS.fetch(request);
//     }
//   };

export default {
  async fetch(request: Request, env: Record<string, unknown>): Promise<Response> {
    // No social features enabled yet — fall through to static assets.
    // The ASSETS binding is provided by wrangler's [assets] config.
    const assets = env.ASSETS as { fetch: typeof fetch } | undefined;
    if (!assets) {
      return new Response("No assets binding configured", { status: 500 });
    }
    return assets.fetch(request);
  },
};
