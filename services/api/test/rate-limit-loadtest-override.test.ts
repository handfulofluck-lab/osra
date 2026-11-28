import { afterEach, describe, expect, it, vi } from "vitest";
import { GLOBAL_RATE_LIMIT, globalRateLimitMax } from "../src/lib/rateLimits.js";

/**
 * Load-test plan (27 Nov 2026): only a stack that says it is a load test may raise the global
 * per-address bucket. Staging and production ignore the variable, and the auth/pairing buckets are
 * not touched by it at all.
 */
describe("globalRateLimitMax", () => {
  afterEach(() => vi.restoreAllMocks());

  it("is the normal limit when nothing is set", () => {
    expect(globalRateLimitMax({})).toBe(GLOBAL_RATE_LIMIT.max);
  });

  it("is raised on a load-test stack", () => {
    expect(globalRateLimitMax({ OSRA_DEPLOYMENT_SCOPE: "loadtest", RATE_LIMIT_GLOBAL_MAX: "1000000" })).toBe(1_000_000);
  });

  it("is ignored on staging and production", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    expect(globalRateLimitMax({ OSRA_DEPLOYMENT_SCOPE: "staging", RATE_LIMIT_GLOBAL_MAX: "1000000" })).toBe(GLOBAL_RATE_LIMIT.max);
    expect(globalRateLimitMax({ NODE_ENV: "production", RATE_LIMIT_GLOBAL_MAX: "1000000" })).toBe(GLOBAL_RATE_LIMIT.max);
    expect(warn).toHaveBeenCalledTimes(2);
  });

  it("refuses a value that is not a number or would lower the limit", () => {
    expect(() => globalRateLimitMax({ OSRA_DEPLOYMENT_SCOPE: "loadtest", RATE_LIMIT_GLOBAL_MAX: "lots" })).toThrow();
    expect(() => globalRateLimitMax({ OSRA_DEPLOYMENT_SCOPE: "loadtest", RATE_LIMIT_GLOBAL_MAX: "10" })).toThrow();
  });
});
