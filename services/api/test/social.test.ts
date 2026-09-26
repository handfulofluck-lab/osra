import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createHmac } from "node:crypto";
import { decryptForFamily, encryptForFamily } from "@familyshield/crypto";
import { socialRoutes } from "../src/routes/social.js";
import { deviceRoutes } from "../src/routes/devices.js";
import { reportsRoutes } from "../src/routes/reports.js";
import { rulesRoutes } from "../src/routes/rules.js";
import { getRedis } from "../src/redis.js";
import { MockRedis, authHeader, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const SECRET = "test-internal-secret";
const VAULT_KEY = Buffer.alloc(32, 7).toString("base64");
const CHILD = { id: "child-1", familyId: "fam-1", birthYear: 2012 };
const FLAGGED_TEXT = "seriously you should kill yourself";

const sign = (raw: string) => createHmac("sha256", SECRET).update(raw).digest("hex");

const aiOk = (body: unknown) =>
  vi.fn(async () => ({ ok: true, json: async () => body })) as unknown as typeof fetch;

/** Post a validly-signed scan request. */
function postScan(app: Awaited<ReturnType<typeof buildApp>>, body: Record<string, unknown>) {
  const raw = JSON.stringify(body);
  return app.inject({
    method: "POST",
    url: "/v1/social/scan",
    headers: { "content-type": "application/json", "x-familyshield-signature": sign(raw) },
    payload: raw,
  });
}

const scanBody = (overrides: Record<string, unknown> = {}) => ({
  childId: CHILD.id,
  app: "whatsapp",
  contact: "bully-1",
  text: FLAGGED_TEXT,
  ...overrides,
});

/** In-memory NX-capable SET implementation for throttle tests. */
const throttleStore = new Map<string, string>();

function mockThrottleSet() {
  const set = getRedis().set as unknown as {
    mockImplementation: (fn: (key: string, value: string, ...rest: unknown[]) => Promise<string | null>) => void;
  };
  set.mockImplementation((key, value, ...rest) => {
    if (rest.includes("NX")) {
      if (throttleStore.has(key)) return Promise.resolve(null);
      throttleStore.set(key, value);
      return Promise.resolve("OK");
    }
    return Promise.resolve("OK");
  });
}

const familyAlertPublishes = () =>
  MockRedis.instances.flatMap((r) => r.publish.mock.calls).filter(
    ([channel, msg]) => channel === "family:fam-1:events" && JSON.parse(msg as string).type === "alert",
  );

describe("social routes", () => {
  beforeEach(() => {
    resetPrismaMock();
    // Publish events now go through the shared lazy singleton (review API-4 fix),
    // so reset call history instead of dropping the instance registry.
    for (const r of MockRedis.instances) r.publish.mockClear();
    throttleStore.clear();
    process.env.INTERNAL_HMAC_SECRET = SECRET;
    process.env.VAULT_KEY = VAULT_KEY;
    process.env.AI_ENGINE_URL = "http://ai-engine:8000";
    mockThrottleSet();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("returns {flagged:false} for clean text and writes no alert or vault row", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiOk({ flagged: false, severity: "info", categories: { safe: 0.95 } }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);

    const res = await postScan(app, scanBody({ text: "want to play soccer later?" }));
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ flagged: false, severity: "info", concernTypes: [] });
    expect(prismaMock.socialEvent.create).not.toHaveBeenCalled();
    expect(prismaMock.alert.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("flags risky text: vault row holds only ciphertext, alert has no preview snippet", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiOk({ flagged: true, severity: "warning", categories: { self_harm: 0.8, safe: 0.2 } }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.socialEvent.create.mockResolvedValue({ id: "se-1" });
    prismaMock.alert.create.mockResolvedValue({ id: "a-1" });

    const res = await postScan(app, scanBody());
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ flagged: true, severity: "warning", concernTypes: ["self_harm"] });

    // The vault row stores the AES-GCM payload — plaintext must never appear.
    const cipher = prismaMock.socialEvent.create.mock.calls[0][0] as {
      data: { previewCipher: string; severity: string; concernTypes: string[]; app: string; contact: string; childId: string };
    };
    expect(cipher.data).toMatchObject({ childId: CHILD.id, app: "whatsapp", contact: "bully-1", severity: "warning", concernTypes: ["self_harm"] });
    expect(cipher.data.previewCipher).not.toContain(FLAGGED_TEXT);
    const payload = JSON.parse(cipher.data.previewCipher) as Parameters<typeof decryptForFamily>[0];
    expect(decryptForFamily(payload, VAULT_KEY)).toBe(FLAGGED_TEXT);

    // The alert metadata carries app/contact/concernTypes only — no snippet.
    const alertData = prismaMock.alert.create.mock.calls[0][0] as { data: Record<string, unknown> };
    expect(alertData.data.category).toBe("social_concern");
    expect(alertData.data.metadata).toEqual({ app: "whatsapp", contact: "bully-1", concernTypes: ["self_harm"] });
    expect(alertData.data.metadata).not.toHaveProperty("preview");

    // The family realtime channel received the alert.
    expect(familyAlertPublishes().length).toBe(1);
    await app.close();
  });

  it("truncates vault snippets to 240 characters before encrypting", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiOk({ flagged: true, severity: "warning", categories: { self_harm: 0.9 } }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    const long = "x".repeat(600);
    const res = await postScan(app, scanBody({ text: long }));
    expect(res.statusCode).toBe(200);
    const cipher = (prismaMock.socialEvent.create.mock.calls[0][0] as { data: { previewCipher: string } }).data;
    const payload = JSON.parse(cipher.previewCipher) as Parameters<typeof decryptForFamily>[0];
    expect(decryptForFamily(payload, VAULT_KEY)).toBe(long.slice(0, 240));
    await app.close();
  });

  it("fails open to a local keyword check when the AI engine is down", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("ECONNREFUSED"); }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.alert.create.mockResolvedValue({ id: "a-1" });

    const res = await postScan(app, scanBody());
    expect(res.statusCode).toBe(200);
    expect(res.json().flagged).toBe(true);
    expect(prismaMock.socialEvent.create).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({ concernTypes: expect.arrayContaining(["self_harm"]) }) }),
    );
    expect(prismaMock.alert.create).toHaveBeenCalled();
    await app.close();
  });

  it("throttles repeat alerts per app within 10 minutes but always writes the vault row", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiOk({ flagged: true, severity: "warning", categories: { self_harm: 0.8, safe: 0.2 } }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.alert.create.mockResolvedValue({ id: "a-1" });

    const first = await postScan(app, scanBody({ text: "first kill yourself" }));
    expect(first.json().flagged).toBe(true);
    const second = await postScan(app, scanBody({ text: "second kill yourself" }));
    expect(second.json().flagged).toBe(true);

    expect(prismaMock.socialEvent.create).toHaveBeenCalledTimes(2);
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);
    expect(familyAlertPublishes().length).toBe(1);
    await app.close();
  });

  it("uses the gaming_chat category for Discord messages", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiOk({ flagged: true, severity: "warning", categories: { cyberbullying: 0.9 } }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.alert.create.mockResolvedValue({ id: "a-1" });

    const res = await postScan(app, scanBody({ app: "discord" }));
    expect(res.statusCode).toBe(200);
    expect((prismaMock.alert.create.mock.calls[0][0] as { data: { category: string } }).data.category).toBe("gaming_chat");
    await app.close();
  });

  it("rejects a scan without a valid HMAC signature (401)", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    const res = await app.inject({ method: "POST", url: "/v1/social/scan", payload: scanBody() });
    expect(res.statusCode).toBe(401);
    expect(prismaMock.socialEvent.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("rejects a well-signed scan with an invalid payload (400)", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    const raw = JSON.stringify({ childId: CHILD.id, app: "whatsapp" }); // missing text
    const res = await app.inject({
      method: "POST",
      url: "/v1/social/scan",
      headers: { "content-type": "application/json", "x-familyshield-signature": sign(raw) },
      payload: raw,
    });
    expect(res.statusCode).toBe(400);
    await app.close();
  });

  it("returns 404 for a well-signed scan naming an unknown child", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiOk({ flagged: false, severity: "info", categories: { safe: 1 } }));
    prismaMock.child.findUnique.mockResolvedValue(null);
    const res = await postScan(app, scanBody());
    expect(res.statusCode).toBe(404);
    expect(res.json().error).toBe("child_not_found");
    await app.close();
  });

  it("lists vault events decrypted, newest first, with filters", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    const previewCipher = JSON.stringify(encryptForFamily("are you alone tonight?", VAULT_KEY));
    prismaMock.socialEvent.findMany.mockResolvedValue([
      { id: "se-1", app: "whatsapp", contact: "c-1", severity: "critical", previewCipher, concernTypes: ["grooming"], createdAt: "2026-09-16T10:00:00Z" },
    ]);

    const res = await app.inject({
      method: "GET",
      url: "/v1/social/events?childId=child-1&app=whatsapp&severity=critical&limit=10",
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(200);
    expect(prismaMock.socialEvent.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { childId: "child-1", app: "whatsapp", severity: "critical" },
        orderBy: { createdAt: "desc" },
        take: 10,
      }),
    );
    const item = res.json().items[0];
    expect(item.preview).toBe("are you alone tonight?");
    expect(item).toMatchObject({ id: "se-1", app: "whatsapp", contact: "c-1", severity: "critical", concernTypes: ["grooming"] });
    await app.close();
  });

  it("requires a parent JWT for the vault (401 without, 403 for device tokens, 403 cross-family)", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    const noAuth = await app.inject({ method: "GET", url: "/v1/social/events?childId=child-1" });
    expect(noAuth.statusCode).toBe(401);

    const device = await app.inject({ method: "GET", url: "/v1/social/events?childId=child-1", headers: deviceHeader(app) });
    expect(device.statusCode).toBe(403);

    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    const foreign = await app.inject({ method: "GET", url: "/v1/social/events?childId=child-1", headers: authHeader(app, "fam-2") });
    expect(foreign.statusCode).toBe(403);
    expect(prismaMock.socialEvent.findMany).not.toHaveBeenCalled();
    await app.close();
  });
});

describe("activity ingest and reports", () => {
  beforeEach(() => {
    resetPrismaMock();
    process.env.VAULT_KEY = VAULT_KEY;
  });

  it("ingests an activity batch with a device JWT (202) and persists via createMany", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } });

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/activity",
      headers: deviceHeader(app),
      payload: {
        events: [
          { type: "url", payload: { url: "https://example.com" } },
          { ts: "2026-09-16T10:00:00.000Z", type: "call", payload: { number: "+201001234567", direction: "in" } },
        ],
      },
    });
    expect(res.statusCode).toBe(202);
    const data = (prismaMock.activityEvent.createMany.mock.calls[0][0] as { data: Array<Record<string, unknown>> }).data;
    expect(data).toHaveLength(2);
    expect(data[0]).toMatchObject({ childId: "child-1", deviceId: "dev-1", type: "url", payload: { url: "https://example.com" } });
    expect(data[0].ts).toBeInstanceOf(Date);
    expect(data[1]).toMatchObject({ type: "call" });
    await app.close();
  });

  it("rejects batches over 500 events and unknown event types (400)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } });

    const tooMany = Array.from({ length: 501 }, () => ({ type: "url", payload: {} }));
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/activity",
      headers: deviceHeader(app),
      payload: { events: tooMany },
    });
    expect(res.statusCode).toBe(400);
    expect(prismaMock.activityEvent.createMany).not.toHaveBeenCalled();
    await app.close();
  });

  it("blocks ingest for a device outside the family (403)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", child: { familyId: "fam-2" } });
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/activity",
      headers: deviceHeader(app, { deviceId: "dev-1", childId: "child-1", familyId: "fam-1" }),
      payload: { events: [{ type: "url", payload: {} }] },
    });
    expect(res.statusCode).toBe(403);
    expect(prismaMock.activityEvent.createMany).not.toHaveBeenCalled();
    await app.close();
  });

  it("lists activity reports filtered by type, scoped to the family, default limit 200", async () => {
    const app = await buildApp(reportsRoutes, "/v1/reports");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.activityEvent.findMany.mockResolvedValue([{ id: "ae-1", type: "call" }]);

    const res = await app.inject({
      method: "GET",
      url: "/v1/reports/activity?childId=child-1&type=call",
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(200);
    expect(prismaMock.activityEvent.findMany).toHaveBeenCalledWith(
      expect.objectContaining({ where: { childId: "child-1", type: "call" }, orderBy: { ts: "desc" }, take: 200 }),
    );
    expect(res.json().items).toEqual([{ id: "ae-1", type: "call" }]);
    await app.close();
  });

  it("passes from/to bounds into the activity report query", async () => {
    const app = await buildApp(reportsRoutes, "/v1/reports");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    await app.inject({
      method: "GET",
      url: "/v1/reports/activity?childId=child-1&from=2026-09-01T00:00:00.000Z&to=2026-09-16T00:00:00.000Z",
      headers: authHeader(app),
    });
    const arg = prismaMock.activityEvent.findMany.mock.calls[0][0] as { where: { ts: { gte: Date; lte: Date } } };
    expect(arg.where.ts.gte).toBeInstanceOf(Date);
    expect(arg.where.ts.lte).toBeInstanceOf(Date);
    await app.close();
  });

  it("requires a parent JWT for reports (401 without, 403 cross-family)", async () => {
    const app = await buildApp(reportsRoutes, "/v1/reports");
    const noAuth = await app.inject({ method: "GET", url: "/v1/reports/activity?childId=child-1" });
    expect(noAuth.statusCode).toBe(401);

    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    const foreign = await app.inject({ method: "GET", url: "/v1/reports/activity?childId=child-1", headers: authHeader(app, "fam-2") });
    expect(foreign.statusCode).toBe(403);
    expect(prismaMock.activityEvent.findMany).not.toHaveBeenCalled();
    await app.close();
  });
});

describe("rules passthrough: socialMonitoring + contactAllowlist", () => {
  const validRuleSet = {
    screenTime: {
      dailyLimitMinutes: 180,
      weekendLimitMinutes: 300,
      bedtimeStart: "21:00",
      bedtimeEnd: "07:00",
      schoolHours: { start: "08:00", end: "15:00", days: [1, 2, 3, 4, 5] },
    },
    webFilter: { blockedCategories: ["pornography"], allowedDomains: [], blockedDomains: [], safeSearchEnforced: true },
    appRules: [],
    routines: [],
    socialMonitoring: { whatsapp: true, tiktok: false },
    contactAllowlist: ["+15551234567", "+201001234567"],
  };

  const flatRow = {
    id: "rs-1",
    childId: "child-1",
    dailyLimitMinutes: 180,
    weekendLimitMinutes: 300,
    bedtimeStart: "21:00",
    bedtimeEnd: "07:00",
    schoolHoursStart: "08:00",
    schoolHoursEnd: "15:00",
    schoolDays: [1, 2, 3, 4, 5],
    blockedCategories: ["pornography"],
    allowedDomains: [],
    blockedDomains: [],
    safeSearchEnforced: true,
    appRules: [],
    routines: [],
    alwaysAllowedApps: [],
    bonusMinutesToday: 0,
    socialMonitoring: { whatsapp: true, tiktok: false },
    contactAllowlist: ["+15551234567", "+201001234567"],
    updatedAt: "2026-09-16T10:00:00.000Z",
  };

  beforeEach(() => {
    resetPrismaMock();
  });

  it("round-trips socialMonitoring and contactAllowlist through PUT", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.ruleSet.upsert.mockResolvedValue(flatRow);
    prismaMock.device.findMany.mockResolvedValue([]);

    const res = await app.inject({
      method: "PUT",
      url: "/v1/rules/child-1",
      headers: authHeader(app),
      payload: validRuleSet,
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().socialMonitoring).toEqual({ whatsapp: true, tiktok: false });
    expect(res.json().contactAllowlist).toEqual(["+15551234567", "+201001234567"]);
    expect(prismaMock.ruleSet.upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        create: expect.objectContaining({
          socialMonitoring: { whatsapp: true, tiktok: false },
          contactAllowlist: ["+15551234567", "+201001234567"],
        }),
        update: expect.objectContaining({ socialMonitoring: { whatsapp: true, tiktok: false } }),
      }),
    );
    await app.close();
  });

  it("defaults the new fields when a legacy ruleset payload omits them", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.ruleSet.upsert.mockResolvedValue(flatRow);
    prismaMock.device.findMany.mockResolvedValue([]);

    const { socialMonitoring: _sm, contactAllowlist: _ca, ...legacy } = validRuleSet;
    const res = await app.inject({
      method: "PUT",
      url: "/v1/rules/child-1",
      headers: authHeader(app),
      payload: legacy,
    });
    expect(res.statusCode).toBe(200);
    expect(prismaMock.ruleSet.upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        create: expect.objectContaining({ socialMonitoring: {}, contactAllowlist: [] }),
      }),
    );
    await app.close();
  });

  it("deep-merges socialMonitoring and contactAllowlist on PATCH", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.ruleSet.upsert.mockResolvedValue(flatRow);
    prismaMock.device.findMany.mockResolvedValue([]);

    const res = await app.inject({
      method: "PATCH",
      url: "/v1/rules/child-1",
      headers: authHeader(app),
      payload: { socialMonitoring: { discord: true } },
    });
    expect(res.statusCode).toBe(200);
    expect(prismaMock.ruleSet.upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        update: expect.objectContaining({ socialMonitoring: { discord: true } }),
      }),
    );
    await app.close();
  });
});
