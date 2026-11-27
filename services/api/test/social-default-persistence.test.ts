import { createHash, randomBytes } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { DEFAULT_RULESET } from "../src/lib/defaultRules.js";
import { signV2 } from "../src/lib/internalAuth.js";
import { familyRoutes } from "../src/routes/family.js";
import { socialRoutes } from "../src/routes/social.js";
import { authHeader, buildApp, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => ({ prisma: (await import("./helpers.js")).prismaMock }));
vi.mock("ioredis", async () => ({ Redis: (await import("./helpers.js")).MockRedis }));

const CHILD_ID = "child-created-through-route";
const DEVICE_ID = "device-for-persisted-default";
const FAMILY_ID = "fam-1";

describe("new-child default persistence to first scan (#1142 review)", () => {
  beforeEach(() => {
    resetPrismaMock();
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
  });

  it("uses the ruleset upserted by child creation, not a mocked read default", async () => {
    // Mutant: dropping socialMonitoring from defaultRuleSetRow leaves {} here, so the
    // staging analyzer is never called even though the old direct-read test stays green.
    const secret = randomBytes(32).toString("hex");
    const text = "A synthetic harmless first message after child creation.";
    let persistedMonitoring: unknown;
    prismaMock.family.findUnique.mockResolvedValue({ id: FAMILY_ID, region: "US", timezone: "UTC" });
    prismaMock.child.create.mockImplementation(async ({ data }) => ({ id: CHILD_ID, ...data }));
    prismaMock.consentRecord.create.mockImplementation(async ({ data }) => ({ id: "consent-created-through-route", ...data }));
    prismaMock.consentRecord.findFirst.mockImplementation(async ({ where }) =>
      where.childId === CHILD_ID
        ? { id: "consent-created-through-route", childId: CHILD_ID, jurisdiction: "US", revokedAt: null, expiresAt: null }
        : null);
    prismaMock.ruleSet.upsert.mockImplementation(async ({ create }) => {
      persistedMonitoring = create.socialMonitoring;
      return create;
    });
    prismaMock.child.findUnique.mockImplementation(async ({ where }) =>
      where.id === CHILD_ID
        ? {
            id: CHILD_ID,
            familyId: FAMILY_ID,
            birthYear: 2014,
            family: { region: "US", timezone: "UTC" },
            ruleSet: { socialMonitoring: persistedMonitoring },
          }
        : null);
    prismaMock.device.findUnique.mockResolvedValue({ id: DEVICE_ID, childId: CHILD_ID, internalSecret: secret });
    prismaMock.socialEvent.create.mockResolvedValue({ id: "event-from-persisted-default" });

    vi.stubEnv("OSRA_DEPLOYMENT_SCOPE", "staging");
    vi.stubEnv("OSRA_STAGING_QA_ANALYZER_ENABLED", "1");
    vi.stubEnv("OSRA_STAGING_QA_ANDROID_SOURCES", "1");
    vi.stubEnv("OSRA_STAGING_QA_DEVICE_ID", DEVICE_ID);
    vi.stubEnv("OSRA_STAGING_QA_CHILD_ID", CHILD_ID);
    vi.stubEnv("OSRA_STAGING_QA_FIXTURE_SHA256", createHash("sha256").update(text).digest("hex"));
    vi.stubEnv("OSRA_STAGING_QA_EXPIRES_AT", new Date(Date.now() + 600_000).toISOString());
    vi.stubEnv("OSRA_STAGING_QA_ANALYZER_URL", "http://qa.internal");
    vi.stubEnv("VAULT_KEY", Buffer.alloc(32, 9).toString("base64"));
    const analyze = vi.fn(async (_url: URL, options: RequestInit) => {
      const request = JSON.parse(String(options.body)) as { trace_id: string };
      return {
        ok: true,
        json: async () => ({
          trace_id: request.trace_id,
          model: "openai.gpt-oss-20b-1:0",
          region: "eu-central-1",
          flagged: true,
          severity: "warning",
          categories: { cyberbullying: 0.9 },
        }),
      };
    });
    vi.stubGlobal("fetch", analyze);

    const app = await buildApp(async (instance) => {
      await instance.register(familyRoutes, { prefix: "/v1/family" });
      await instance.register(socialRoutes, { prefix: "/v1/social" });
    }, "/");
    try {
      const created = await app.inject({
        method: "POST",
        url: "/v1/family/children",
        headers: authHeader(app, FAMILY_ID),
        payload: {
          displayName: "Persisted Child",
          birthYear: 2014,
          consent: { method: "sms_plus", jurisdiction: "US" },
        },
      });
      expect(created.statusCode).toBe(201);
      expect(persistedMonitoring).toEqual(DEFAULT_RULESET.socialMonitoring);

      const raw = JSON.stringify({
        deviceId: DEVICE_ID,
        childId: CHILD_ID,
        app: "whatsapp",
        source: "notification",
        text,
      });
      const scanned = await app.inject({
        method: "POST",
        url: "/v1/social/scan",
        headers: { "content-type": "application/json", ...signV2(secret, raw) },
        payload: raw,
      });
      expect(scanned.statusCode).toBe(200);
      expect(scanned.json()).toMatchObject({ flagged: true });
      expect(analyze).toHaveBeenCalledTimes(1);
      expect(prismaMock.socialEvent.create).toHaveBeenCalledTimes(1);
    } finally {
      await app.close();
    }
  });
});
