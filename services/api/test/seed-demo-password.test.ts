import { describe, expect, it } from "vitest";
import { resolveDemoPassword } from "../scripts/seed-password.js";

// The seed resolves the demo parent's password through this function (scripts/seed.ts). The behaviour
// under test is the refusal: the committed default is public, so a production seed must not use it.
describe("seed demo password", () => {
  it("refuses to resolve under NODE_ENV=production without SEED_DEMO_PASSWORD", () => {
    expect(() => resolveDemoPassword({ NODE_ENV: "production" })).toThrow(
      "SEED_DEMO_PASSWORD is required when NODE_ENV=production: the default demo password is public",
    );
  });

  it("uses the injected SEED_DEMO_PASSWORD under NODE_ENV=production", () => {
    expect(
      resolveDemoPassword({ NODE_ENV: "production", SEED_DEMO_PASSWORD: "injected-by-secrets-manager" }),
    ).toBe("injected-by-secrets-manager");
  });
});
