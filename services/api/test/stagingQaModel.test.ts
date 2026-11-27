import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import { stagingQaDeadline, stagingQaModel } from "../src/lib/stagingQaModel.js";

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

  describe("explicit cross-app staging session", () => {
    const apps = ["whatsapp", "instagram", "tiktok", "snapchat", "twitter", "discord", "roblox", "line", "youtube", "telegram", "reddit", "messenger"];
    const matrixEnv = { ...env, OSRA_STAGING_QA_ANDROID_SOURCES: "1", OSRA_STAGING_QA_ALLOW_SYNTHETIC_PAIR_TEXT: "1" };

    // A WhatsApp-only selector or a source-only selector loses part of the matrix.
    it.each(apps)("routes enabled %s notifications and screen scans with fresh wording", (app) => {
      for (const source of ["notification", "screen"]) {
        const sample = { ...capture, app, source, socialMonitoring: { [app]: true }, text: "On prépare le match de demain." };
        expect(stagingQaModel(sample, matrixEnv, now)).toMatchObject({ fixtureNumber: null });
      }
    });

    it("preserves the digest requirement when exploratory wording is off", () => {
      const sample = { ...capture, app: "line", source: "screen", socialMonitoring: { line: true } };
      const exact = { ...env, OSRA_STAGING_QA_ANDROID_SOURCES: "1" };
      expect(stagingQaModel(sample, exact, now)?.fixtureNumber).toBe(1);
      expect(stagingQaModel({ ...sample, text: "Different fixture" }, exact, now)).toBeNull();
    });

    it.each([
      { app: "unlisted", socialMonitoring: { unlisted: true } }, { source: "unknown" },
      { socialMonitoring: undefined }, { socialMonitoring: { discord: false } },
      { socialMonitoring: { discord: "true" } }, { childId: "another-child" }, { deviceId: "another-device" },
    ])("keeps ineligible captures out of cross-app mode %j", override => {
      const sample = { ...capture, app: "discord", source: "screen", socialMonitoring: { discord: true }, ...override };
      expect(stagingQaModel(sample, matrixEnv, now)).toBeNull();
    });

    it("fails closed on an unrecognized source mode and an expired or non-staging window", () => {
      const sample = { ...capture, socialMonitoring: { whatsapp: true } };
      for (const override of [
        { OSRA_STAGING_QA_ANDROID_SOURCES: "yes" }, { OSRA_DEPLOYMENT_SCOPE: "production" },
        { OSRA_STAGING_QA_EXPIRES_AT: new Date(now).toISOString() },
      ]) expect(stagingQaModel(sample, { ...matrixEnv, ...override }, now)).toBeNull();
    });
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
    { OSRA_STAGING_QA_ENGINE: "unexpected" }, { OSRA_STAGING_QA_ENGINE: "" },
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

describe("staging model request budget", () => {
  it.each([
    ["own", 10000], ["both", 2600], ["bedrock", 2600], [undefined, 2600],
  ] as const)("sets the bounded deadline for %s", (mode, expected) => {
    const qa = stagingQaModel(capture, { ...env, OSRA_STAGING_QA_ENGINE: mode }, now)!;
    // Mutant: widening all provider modes would change the existing Bedrock behavior.
    const budget = stagingQaDeadline(qa, now + 25000, now) - now;
    expect(budget).toBe(expected);
    if (mode === "own") {
      expect(budget).toBeGreaterThan(9000);
      expect(budget).toBeLessThan(30000);
      expect(stagingQaDeadline(qa, now + 300, now)).toBe(now + 300);
      expect(stagingQaDeadline(qa, now - 1, now)).toBeLessThan(now);
    }
    expect(stagingQaDeadline({ ...qa, expiresAt: now + 100 }, Infinity, now)).toBe(now + 100);
  });
});

describe("Parent-saved X / twitter socialMonitoring key (#1036)", () => {
  it("accepts a Parent-saved twitter=true capture on staging cross-app mode and rejects twitter=false", () => {
    const crossAppEnv = { ...env, OSRA_STAGING_QA_ANDROID_SOURCES: "1", OSRA_STAGING_QA_ALLOW_SYNTHETIC_PAIR_TEXT: "1" };
    for (const source of ["notification", "screen"]) {
      expect(stagingQaModel({ ...capture, app: "twitter", source, socialMonitoring: { twitter: true } }, crossAppEnv, now)).not.toBeNull();
      expect(stagingQaModel({ ...capture, app: "twitter", source, socialMonitoring: { twitter: false } }, crossAppEnv, now)).toBeNull();
    }
  });
});

describe("consented staging own-model scoring", () => {
  const { OSRA_STAGING_QA_EXPIRES_AT: _expiry, OSRA_STAGING_QA_FIXTURE_SHA256: _fixtures, ...base } = env;
  const broad = {
    ...base,
    OSRA_STAGING_AI_ALL_CHILDREN: "1",
    OSRA_STAGING_QA_ENGINE: "own",
    OSRA_OWN_MODEL_REGION: "eu-north-1",
  };
  const other = {
    id: "second-paired-device",
    childId: "second-test-child",
  };
  const sample = {
    ...capture, device: other, deviceId: other.id, childId: other.childId,
    app: "discord", source: "screen", socialMonitoring: { discord: true },
  };

  it("selects the existing private analyzer for a second opted-in pairing without fixture expiry", () => {
    const selected = stagingQaModel(sample, broad, now);
    expect(selected).toMatchObject({ providerMode: "own", allChildren: true, fixtureNumber: null });
    expect(selected?.endpoint.pathname).toBe("/analyze/staging-qa");
    expect(stagingQaDeadline(selected!, now + 25_000, now)).toBe(now + 10_000);
  });

  it.each([
    { OSRA_DEPLOYMENT_SCOPE: "production" },
    { OSRA_DEPLOYMENT_SCOPE: undefined },
    { OSRA_STAGING_AI_ALL_CHILDREN: undefined },
    { OSRA_STAGING_QA_ANALYZER_ENABLED: "0" },
    { OSRA_STAGING_QA_ENGINE: "both" },
    { OSRA_STAGING_QA_ENGINE: "bedrock" },
    { OSRA_OWN_MODEL_REGION: "eu-central-1" },
    { AWS_REGION: "eu-central-1" },
    { OSRA_STAGING_QA_ANALYZER_URL: "http://qa.local" },
  ])("fails closed when the broad deployment setting is invalid: %j", (override) => {
    expect(stagingQaModel(sample, { ...broad, ...override }, now)).toBeNull();
  });

  it.each([
    { socialMonitoring: { discord: false } }, { socialMonitoring: { discord: "true" } },
    { socialMonitoring: {} }, { childId: "unpaired-child" }, { device: null },
    { source: undefined }, { app: "sms", socialMonitoring: { sms: true } },
    { text: "🙂".repeat(257) }, { text: "   " },
  ])("does not authorize an ineligible capture: %j", (override) => {
    expect(stagingQaModel({ ...sample, ...override }, broad, now)).toBeNull();
  });
});
