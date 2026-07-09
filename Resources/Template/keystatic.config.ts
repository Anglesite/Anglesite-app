import { collection, config, fields } from "@keystatic/core";

// storage: "local" writes straight to files in the repo — no cloud account, no GitHub App.
// Git stays the source of truth. Toggled-on integrations (see IntegrationCatalog.swift) inject
// their collection() blocks at the anglesite:keystatic-collections anchor below.
export default config({
  storage: { kind: "local" },
  collections: {
    // anglesite:keystatic-collections
  },
  singletons: {
    // anglesite:keystatic-singletons
  },
});
