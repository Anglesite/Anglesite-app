import { fileURLToPath } from "node:url";
import type { AstroIntegration } from "astro";

/**
 * Dev-only component harness for the Anglesite Component Editor.
 * Injects /_anglesite/component/[...name] in `astro dev` and nothing in
 * builds, so deployed sites carry no trace of it.
 */
export default function anglesiteHarness(): AstroIntegration {
  return {
    name: "anglesite-harness",
    hooks: {
      "astro:config:setup": ({ command, injectRoute }) => {
        if (command !== "dev") return;
        injectRoute({
          pattern: "/_anglesite/component/[...name]",
          entrypoint: fileURLToPath(new URL("./harness/component.astro", import.meta.url)),
          prerender: false,
        });
      },
    },
  };
}
