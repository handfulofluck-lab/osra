import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import { stagingQaModel } from "../src/lib/stagingQaModel.js";

const now = Date.parse("2026-11-21T03:35:00Z");
const text = "A synthetic staging fixture.";
const paired = { id: "device-fixture", childId: "child-fixture" };
const capture = { device: paired, deviceId: paired.id, childId: paired.childId, app: "whatsapp", source: "notification", text };
const env = {
  OSRA_DEPLOYMENT_SCOPE: "staging",
  OSRA_STAGING_QA_ANALYZER_ENABLED: "1",
  OSRA_STAGING_QA_DEVICE_ID: paired.id,
  OSRA_STAGING_QA_CHILD_ID: paired.childId,
  OSRA_STAGING_QA_EXPIRES_AT: new Date(now + 15 * 60 * 1000).toISOString(),
  OSRA_STAGING_QA_FIXTURE_SHA256: createHash("sha256").update(text).digest("hex"),
  OSRA_STAGING_QA_ANALYZER_URL: "http://ai-engine.osra-qa.internal:8000",
};

describe("staging QA model gate", () => {
  it("selects one private endpoint and a fresh trace for the exact approved capture", () => {
    const selected = stagingQaModel(capture, env, now);
    expect(selected?.endpoint.href).toBe("http://ai-engine.osra-qa.internal:8000/analyze/staging-qa");
    expect(selected?.fixtureNumber).toBe(1);
    expect(stagingQaModel(capture, env, now)?.traceId).not.toBe(selected?.traceId);
  });

  it("accepts new wording only when the synthetic pair mode is explicitly enabled", () => {
    const sample = { ...capture, text: "A sentence chosen during the test." };
    expect(stagingQaModel(sample, env, now)).toBeNull();
    expect(stagingQaModel(sample, {
      ...env, OSRA_STAGING_QA_ALLOW_SYNTHETIC_PAIR_TEXT: "1",
    }, now)?.fixtureNumber).toBeNull();
  });

  it.each([
    { device: null }, { deviceId: undefined }, { childId: "another-child" },
    { app: "sms" }, { source: "screen" }, { text: "A different fixture." },
  ])("does not select mismatched capture %j", (override) => {
    expect(stagingQaModel({ ...capture, ...override }, env, now)).toBeNull();
  });

  it.each([
    { device: null }, { deviceId: "another-device" }, { childId: "another-child" },
    { app: "sms" }, { source: "screen" }, { text: "" }, { text: "🎈".repeat(257) },
  ])("rejects capture outside the synthetic pair mode boundary %j", (override) => {
    expect(stagingQaModel({ ...capture, ...override }, {
      ...env, OSRA_STAGING_QA_ALLOW_SYNTHETIC_PAIR_TEXT: "1",
    }, now)).toBeNull();
  });

  it.each([
    { OSRA_DEPLOYMENT_SCOPE: "production" }, { OSRA_STAGING_QA_ANALYZER_ENABLED: "0" },
    { OSRA_STAGING_QA_EXPIRES_AT: new Date(now).toISOString() },
    { OSRA_STAGING_QA_EXPIRES_AT: new Date(now + 61 * 60 * 1000).toISOString() },
    { OSRA_STAGING_QA_FIXTURE_SHA256: "invalid" }, { OSRA_STAGING_QA_ALLOW_SYNTHETIC_PAIR_TEXT: "yes" },
    { OSRA_STAGING_QA_ANALYZER_URL: "https://example.com" },
    { OSRA_STAGING_QA_ANALYZER_URL: "https://ai-engine.osra-qa.internal/unrelated" },
  ])("defaults to no model for invalid deployment config %j", (override) => {
    expect(stagingQaModel(capture, { ...env, ...override }, now)).toBeNull();
  });
});
