import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      main: "./worker/worker.ts",
      miniflare: {
        compatibilityDate: "2026-07-15",
        compatibilityFlags: ["nodejs_compat"],
        d1Databases: ["AUTH_DB", "WEBMENTION_INBOX", "MICROPUB_DB", "WEBSUB_DB", "MICROSUB_DB"],
        kvNamespaces: ["INBOX_KV", "SOCIAL_KV"],
        r2Buckets: ["MEDIA"],
        queueProducers: {
          WEBMENTION_QUEUE: "site-webmention",
          WEBSUB_QUEUE: "site-websub",
          MICROSUB_QUEUE: "site-microsub",
        },
        // site-websub/site-microsub are deliberately NOT registered as consumers here: a
        // delivered job would make the library's consumer attempt a real network fetch (a
        // verification GET for websub, a feed fetch for microsub) that fails in the test
        // sandbox and schedules a queue retry, which the pool tears down as an "uncaught
        // exception" after the suite passes. The consumer dispatch itself is covered by calling
        // worker.queue directly with a stubbed batch.
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
