import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      main: "./worker/worker.ts",
      miniflare: {
        compatibilityDate: "2026-07-15",
        compatibilityFlags: ["nodejs_compat"],
        d1Databases: ["AUTH_DB", "WEBMENTION_INBOX", "MICROPUB_DB"],
        kvNamespaces: ["INBOX_KV", "SOCIAL_KV"],
        r2Buckets: ["MEDIA"],
        queueProducers: { WEBMENTION_QUEUE: "site-webmentions" },
        queueConsumers: ["site-webmentions"],
        bindings: {
          TOKEN_SIGNING_KEY: "test-token-signing-key-with-at-least-32-bytes",
          INDIEAUTH_OWNER_PASSWORD: "correct horse battery staple",
          SITE_URL: "https://test.example",
        },
      },
    }),
  ],
  test: {
    include: ["worker/**/*.test.ts"],
  },
});
