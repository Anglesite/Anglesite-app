import { describe, it, expect } from "vitest";

// Sanity check — confirms the vitest pipeline is wired up before any real source modules exist.
// Deletable once the real tests are in place.
describe("vitest pipeline", () => {
  it("runs", () => {
    expect(1 + 1).toBe(2);
  });
});
