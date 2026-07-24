import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      main: "./worker/worker.ts",
      miniflare: {
        compatibilityDate: "2026-07-15",
        compatibilityFlags: ["nodejs_compat"],
        d1Databases: ["AUTH_DB", "WEBMENTION_INBOX", "MICROPUB_DB", "WEBSUB_DB"],
        kvNamespaces: ["INBOX_KV", "SOCIAL_KV"],
        r2Buckets: ["MEDIA"],
        queueProducers: { WEBMENTION_QUEUE: "site-webmention", WEBSUB_QUEUE: "site-websub" },
        // site-websub is deliberately NOT registered as a consumer here: a delivered verify job
        // would make @dwk/websub's consumer attempt a real verification GET to the test's fake
        // subscriber callback and schedule a queue retry when it fails, which the pool tears
        // down as an "uncaught exception" after the suite passes. The consumer dispatch itself
        // is covered by calling worker.queue directly with a stubbed batch.
        queueConsumers: ["site-webmention"],
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
