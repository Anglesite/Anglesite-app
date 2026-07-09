import { defineConfig } from "astro/config";
import keystatic from "@keystatic/astro";
import react from "@astrojs/react";
import node from "@astrojs/node";
import { readConfig } from "./scripts/config.ts";
import anglesiteHarness from "./scripts/anglesite-harness.ts";

// The deploy step writes the real domain into `.site-config` (SITE_URL=…) before build.
// Absent that, feeds carry a placeholder host — fine for a not-yet-deployed scaffold.
const site = readConfig("SITE_URL") ?? "https://example.com";

// Keystatic (`react`, `keystatic`) mounts the /keystatic admin UI in dev only — it does not
// register a route during `astro build`. `pre-deploy-check.ts`'s BLOCKED_ROUTES check is a
// defense-in-depth backstop, not the primary reason /keystatic never reaches production.
export default defineConfig({
  adapter: node({ mode: "middleware" }),
  site,
  integrations: [anglesiteHarness(), react(), keystatic()],
});
