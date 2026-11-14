import { describe, expect, it } from "vitest";
import { assertCorsConfigured } from "../src/lib/corsConfig.js";

describe("production CORS must be configured (#765, Fable B4)", () => {
  it("refuses a production boot with no CORS_ORIGIN", () => {
    expect(() => assertCorsConfigured({ NODE_ENV: "production" })).toThrow(/CORS_ORIGIN must be set/);
  });
  it("refuses a wildcard origin in production", () => {
    expect(() => assertCorsConfigured({ NODE_ENV: "production", CORS_ORIGIN: "*" })).toThrow(/not '\*'/);
  });
  it("accepts named origins in production", () => {
    expect(() => assertCorsConfigured({ NODE_ENV: "production", CORS_ORIGIN: "https://app.osratech.com" })).not.toThrow();
  });
  it("accepts an explicit any-origin opt-in (staging, CI image check)", () => {
    expect(() => assertCorsConfigured({ NODE_ENV: "production", CORS_ALLOW_ANY_ORIGIN: "1" })).not.toThrow();
  });
  it("leaves development alone", () => {
    expect(() => assertCorsConfigured({ NODE_ENV: "development" })).not.toThrow();
    expect(() => assertCorsConfigured({})).not.toThrow();
  });
});
