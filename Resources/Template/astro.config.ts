import { defineConfig } from "astro/config";
import keystatic from "@keystatic/astro";
import react from "@astrojs/react";
import { readConfig } from "./scripts/config.ts";
import anglesiteHarness from "./scripts/anglesite-harness.ts";

// The deploy step writes the real domain into `.site-config` (SITE_URL=…) before build.
// Absent that, feeds carry a placeholder host — fine for a not-yet-deployed scaffold.
const site = readConfig("SITE_URL") ?? "https://example.com";

// Keystatic's /keystatic admin UI is dev-only: gated on the `astro dev` CLI subcommand via
// process.argv (Astro's own defineConfig doesn't support a function-form config in this
// version — see git history for why that approach was tried and reverted). This keeps
// production builds pure static output with no server adapter: `react()`/`keystatic()` are
// never registered outside `astro dev`, so `astro build` never sees their routes at all.
const isDev = process.argv.includes("dev");

export default defineConfig({
  site,
  integrations: [anglesiteHarness(), ...(isDev ? [react(), keystatic()] : [])],
});
