import { defineConfig } from "astro/config";
import { readConfig } from "./scripts/config.ts";

// The deploy step writes the real domain into `.site-config` (SITE_URL=…) before build.
// Absent that, feeds carry a placeholder host — fine for a not-yet-deployed scaffold.
const site = readConfig("SITE_URL") ?? "https://example.com";

export default defineConfig({ site });
