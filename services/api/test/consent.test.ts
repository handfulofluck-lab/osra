import { beforeEach, describe, expect, it, vi } from "vitest";
import Fastify, { type FastifyInstance } from "fastify";
import fastifyJwt from "@fastify/jwt";
import { familyRoutes } from "../src/routes/family.js";
import { rulesRoutes } from "../src/routes/rules.js";
import { deviceRoutes } from "../src/routes/devices.js";
import { controlsRoutes } from "../src/routes/controls.js";
import { locationRoutes } from "../src/routes/location.js";
import { MockRedis, authHeader, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const FAMILY = { id: "fam-1", name: "Demo Family", region: "US" };
const CHILD_ID = "child-1";

async function buildConsentApp(): Promise<FastifyInstance> {
  const app = Fastify({ logger: false });
  await app.register(fastifyJwt, { secret: "test-secret" });
  await app.register(familyRoutes, { prefix: "/v1/family" });
  await app.register(rulesRoutes, { prefix: "/v1/rules" });
  await app.register(deviceRoutes, { prefix: "/v1/devices" });
  await app.register(controlsRoutes, { prefix: "/v1/controls" });
  await app.register(locationRoutes, { prefix: "/v1/location" });
  await app.ready();
  return app;
}

describe("parental consent revocation and gate enforcement (spec §12.5, ADR-0008, Issue #43)", () => {
  beforeEach(() => {
    resetPrismaMock();
  });

  it("POST /v1/family/children/:id/consent/revoke revokes active consent records (200)", async () => {
    const app = await buildConsentApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1", family: FAMILY });
    prismaMock.consentRecord.updateMany.mockResolvedValue({ count: 2 });

    const res = await app.inject({
      method: "POST",
      url: `/v1/family/children/${CHILD_ID}/consent/revoke`,
      headers: authHeader(app, "fam-1"),
    });

    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.revoked).toBe(true);
    expect(body.childId).toBe(CHILD_ID);
    expect(body.count).toBe(2);
    expect(body.revokedAt).toBeDefined();

    expect(prismaMock.consentRecord.updateMany).toHaveBeenCalledWith({
      where: { childId: CHILD_ID, revokedAt: null },
      data: { revokedAt: expect.any(Date) },
    });
    await app.close();
  });

  it("POST /v1/family/children/:id/consent/revoke returns 403 for another family's child", async () => {
    const app = await buildConsentApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-2" });

    const res = await app.inject({
      method: "POST",
      url: `/v1/family/children/${CHILD_ID}/consent/revoke`,
      headers: authHeader(app, "fam-1"),
    });

    expect(res.statusCode).toBe(403);
    expect(prismaMock.consentRecord.updateMany).not.toHaveBeenCalled();
    await app.close();
  });

  it("GET /v1/family/children/:id/consent reports active status and jurisdiction", async () => {
    const app = await buildConsentApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });

    const res = await app.inject({
      method: "GET",
      url: `/v1/family/children/${CHILD_ID}/consent`,
      headers: authHeader(app, "fam-1"),
    });

    expect(res.statusCode).toBe(200);
    expect(res.json().active).toBe(true);
    expect(res.json().jurisdiction).toBe("US");
    await app.close();
  });

  it("GET .../consent keeps a revoked record visible in `records` (the screen must not infer 'none')", async () => {
    const app = await buildConsentApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    // checkActiveConsent finds nothing active ...
    prismaMock.consentRecord.findFirst.mockResolvedValue(null);
    // ... but the history still holds the real row.
    const grantedAt = new Date("2026-09-01T08:00:00.000Z");
    const revokedAt = new Date("2026-10-01T09:30:00.000Z");
    prismaMock.consentRecord.findMany.mockResolvedValue([{
      id: "consent-revoked",
      childId: CHILD_ID,
      parentId: "parent-1",
      method: "kba",
      jurisdiction: "US",
      grantedAt,
      expiresAt: null,
      revokedAt,
      thirdPartySharing: true,
    }]);

    const res = await app.inject({
      method: "GET",
      url: `/v1/family/children/${CHILD_ID}/consent`,
      headers: authHeader(app, "fam-1"),
    });

    expect(res.statusCode).toBe(200);
    expect(res.json().active).toBe(false);
    expect(res.json().reason).toBe("parental_consent_required");
    expect(res.json().records).toHaveLength(1);
    expect(res.json().records[0]).toMatchObject({
      id: "consent-revoked",
      method: "kba",
      jurisdiction: "US",
      grantedAt: grantedAt.toISOString(),
      expiresAt: null,
      revokedAt: revokedAt.toISOString(),
      thirdPartySharing: true,
    });
    expect(prismaMock.consentRecord.findMany).toHaveBeenCalledWith({
      where: { childId: CHILD_ID },
      orderBy: { grantedAt: "desc" },
      take: 20,
      select: {
        id: true,
        childId: true,
        parentId: true,
        method: true,
        jurisdiction: true,
        grantedAt: true,
        expiresAt: true,
        revokedAt: true,
        thirdPartySharing: true,
      },
    });
    await app.close();
  });

  it("revoke tells every device of the child to pause monitoring (consent_revoked command)", async () => {
    const app = await buildConsentApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.device.findMany.mockResolvedValue([{ id: "dev-1" }, { id: "dev-2" }]);
    prismaMock.deviceCommand.create.mockClear();

    const res = await app.inject({
      method: "POST",
      url: `/v1/family/children/${CHILD_ID}/consent/revoke`,
      headers: authHeader(app, "fam-1"),
    });

    expect(res.statusCode).toBe(200);
    expect(res.json().devicesNotified).toBe(2);
    // Phase 2b: the command is a durable row per device, not a Redis list entry.
    const queued = prismaMock.deviceCommand.create.mock.calls
      .map(([arg]: [{ data: { deviceId: string; type: string } }]) => arg.data)
      .filter((d) => d.type === "consent_revoked")
      .map((d) => d.deviceId);
    expect(queued.sort()).toEqual(["dev-1", "dev-2"]);
    await app.close();
  });

  // ADR-0008 §2b — withdrawal of consent stops *collection*, not only configuration.

  it("POST /v1/location/ping from a device returns 428 once consent is revoked", async () => {
    const app = await buildConsentApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.consentRecord.findFirst.mockResolvedValue(null);

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: deviceHeader(app),
      payload: { childId: CHILD_ID, deviceId: "dev-1", lat: 1, lng: 2, accuracyM: 5, timestamp: new Date().toISOString() },
    });

    expect(res.statusCode).toBe(428);
    expect(res.json().error).toBe("parental_consent_required");
    expect(prismaMock.locationPing.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("GET /v1/rules/:childId returns 428 to the device but 200 to the parent once consent is revoked", async () => {
    const app = await buildConsentApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.consentRecord.findFirst.mockResolvedValue(null);
    prismaMock.ruleSet.findUnique.mockResolvedValue(null);

    const asDevice = await app.inject({ method: "GET", url: `/v1/rules/${CHILD_ID}`, headers: deviceHeader(app) });
    const asParent = await app.inject({ method: "GET", url: `/v1/rules/${CHILD_ID}`, headers: authHeader(app, "fam-1") });

    expect(asDevice.statusCode).toBe(428);
    expect(asParent.statusCode).toBe(200);
    await app.close();
  });

  it("GET /v1/devices/:id/commands returns 428 to the device once consent is revoked", async () => {
    const app = await buildConsentApp();
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: CHILD_ID, child: { familyId: "fam-1" } });
    prismaMock.consentRecord.findFirst.mockResolvedValue(null);

    const res = await app.inject({ method: "GET", url: "/v1/devices/dev-1/commands", headers: deviceHeader(app) });

    expect(res.statusCode).toBe(428);
    await app.close();
  });

  // ADR-0008 §2c — safe-direction actions never require consent.

  it("POST /v1/controls/children/:childId/resume stays available (200) once consent is revoked", async () => {
    const app = await buildConsentApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.consentRecord.findFirst.mockResolvedValue(null);

    const res = await app.inject({
      method: "POST",
      url: `/v1/controls/children/${CHILD_ID}/resume`,
      headers: authHeader(app, "fam-1"),
    });

    expect(res.statusCode).toBe(200);
    await app.close();
  });

  it("POST /v1/devices/:id/command: lock is 428 but unlock is 200 once consent is revoked", async () => {
    const app = await buildConsentApp();
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: CHILD_ID, child: { familyId: "fam-1" } });
    prismaMock.consentRecord.findFirst.mockResolvedValue(null);

    const lock = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/command",
      headers: authHeader(app, "fam-1"),
      payload: { command: "lock" },
    });
    const unlock = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/command",
      headers: authHeader(app, "fam-1"),
      payload: { command: "unlock" },
    });

    // Plan 1.7: stop_ring reduces restriction, so it stays available; locate_now does not.
    const stopRing = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/command",
      headers: authHeader(app, "fam-1"),
      payload: { command: "stop_ring" },
    });
    const locate = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/command",
      headers: authHeader(app, "fam-1"),
      payload: { command: "locate_now" },
    });

    expect(lock.statusCode).toBe(428);
    expect(unlock.statusCode).toBe(200);
    expect(stopRing.statusCode).toBe(200);
    expect(locate.statusCode).toBe(428);
    await app.close();
  });

  it("PUT /v1/rules/:childId returns 428 when consent is revoked", async () => {
    const app = await buildConsentApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1", family: FAMILY });
    // Consent record revoked
    prismaMock.consentRecord.findFirst.mockResolvedValue(null);

    const res = await app.inject({
      method: "PUT",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app, "fam-1"),
      payload: {
        screenTime: {
          dailyLimitMinutes: 120,
          weekendLimitMinutes: 180,
          bedtimeStart: "21:00",
          bedtimeEnd: "07:00",
          schoolHours: { start: "08:00", end: "15:00", days: [1, 2, 3, 4, 5] },
        },
        webFilter: {
          blockedCategories: [],
          allowedDomains: [],
          blockedDomains: [],
          safeSearchEnforced: true,
        },
        appRules: [],
        routines: [],
      },
    });

    expect(res.statusCode).toBe(428);
    expect(res.json().error).toBe("parental_consent_required");
    expect(prismaMock.ruleSet.upsert).not.toHaveBeenCalled();
    await app.close();
  });

  it("PUT /v1/rules/:childId returns 428 when consent is expired", async () => {
    const app = await buildConsentApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1", family: FAMILY });
    // findFirst filter includes expiresAt > now, so expired returns null
    prismaMock.consentRecord.findFirst.mockResolvedValue(null);

    const res = await app.inject({
      method: "PUT",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app, "fam-1"),
      payload: {
        screenTime: {
          dailyLimitMinutes: 120,
          weekendLimitMinutes: 180,
          bedtimeStart: "21:00",
          bedtimeEnd: "07:00",
          schoolHours: { start: "08:00", end: "15:00", days: [1, 2, 3, 4, 5] },
        },
        webFilter: {
          blockedCategories: [],
          allowedDomains: [],
          blockedDomains: [],
          safeSearchEnforced: true,
        },
        appRules: [],
        routines: [],
      },
    });

    expect(res.statusCode).toBe(428);
    expect(res.json().error).toBe("parental_consent_required");
    await app.close();
  });

  it("PUT /v1/rules/:childId returns 428 when consent jurisdiction does not match family region", async () => {
    const app = await buildConsentApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1", family: FAMILY });
    prismaMock.family.findUnique.mockResolvedValue(FAMILY); // region: "US"
    prismaMock.consentRecord.findFirst.mockResolvedValue({
      id: "consent-eu",
      childId: CHILD_ID,
      jurisdiction: "EU", // mismatch!
      revokedAt: null,
      expiresAt: null,
    });

    const res = await app.inject({
      method: "PUT",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app, "fam-1"),
      payload: {
        screenTime: {
          dailyLimitMinutes: 120,
          weekendLimitMinutes: 180,
          bedtimeStart: "21:00",
          bedtimeEnd: "07:00",
          schoolHours: { start: "08:00", end: "15:00", days: [1, 2, 3, 4, 5] },
        },
        webFilter: {
          blockedCategories: [],
          allowedDomains: [],
          blockedDomains: [],
          safeSearchEnforced: true,
        },
        appRules: [],
        routines: [],
      },
    });

    expect(res.statusCode).toBe(428);
    expect(res.json().error).toBe("consent_jurisdiction_mismatch");
    expect(res.json().jurisdiction).toBe("US");
    await app.close();
  });

  it("PATCH /v1/family/children/:id returns 428 when consent is revoked", async () => {
    const app = await buildConsentApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1", family: FAMILY });
    prismaMock.consentRecord.findFirst.mockResolvedValue(null);

    const res = await app.inject({
      method: "PATCH",
      url: `/v1/family/children/${CHILD_ID}`,
      headers: authHeader(app, "fam-1"),
      payload: { displayName: "Updated Name" },
    });

    expect(res.statusCode).toBe(428);
    expect(res.json().error).toBe("parental_consent_required");
    expect(prismaMock.child.update).not.toHaveBeenCalled();
    await app.close();
  });

  it("POST /v1/devices/pair returns 428 when consent is revoked", async () => {
    const app = await buildConsentApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1", family: FAMILY });
    prismaMock.consentRecord.findFirst.mockResolvedValue(null);

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/pair",
      headers: authHeader(app, "fam-1"),
      payload: { childId: CHILD_ID },
    });

    expect(res.statusCode).toBe(428);
    expect(res.json().error).toBe("parental_consent_required");
    await app.close();
  });

  it("POST /v1/devices/register returns 428 when consent is revoked", async () => {
    const app = await buildConsentApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1", family: FAMILY });
    prismaMock.consentRecord.findFirst.mockResolvedValue(null);

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/register",
      headers: authHeader(app, "fam-1"),
      payload: { childId: CHILD_ID, platform: "android", model: "Pixel", osVersion: "14" },
    });

    expect(res.statusCode).toBe(428);
    expect(res.json().error).toBe("parental_consent_required");
    expect(prismaMock.device.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("POST /v1/controls/children/:childId/pause returns 428 when consent is revoked", async () => {
    const app = await buildConsentApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1", family: FAMILY });
    prismaMock.consentRecord.findFirst.mockResolvedValue(null);

    const res = await app.inject({
      method: "POST",
      url: `/v1/controls/children/${CHILD_ID}/pause`,
      headers: authHeader(app, "fam-1"),
    });

    expect(res.statusCode).toBe(428);
    expect(res.json().error).toBe("parental_consent_required");
    await app.close();
  });

  it("POST /v1/location/geofences returns 428 when consent is revoked", async () => {
    const app = await buildConsentApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1", family: FAMILY });
    prismaMock.consentRecord.findFirst.mockResolvedValue(null);

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/geofences",
      headers: authHeader(app, "fam-1"),
      payload: { childId: CHILD_ID, label: "Home", lat: 40.7, lng: -74.0, radiusM: 100 },
    });

    expect(res.statusCode).toBe(428);
    expect(res.json().error).toBe("parental_consent_required");
    expect(prismaMock.geofence.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("re-granting consent via POST /v1/family/children/:id/consent unblocks child-scoped writes", async () => {
    const app = await buildConsentApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1", family: FAMILY });
    prismaMock.family.findUnique.mockResolvedValue(FAMILY);

    // 1. Re-grant consent
    prismaMock.consentRecord.create.mockResolvedValue({
      id: "consent-fresh",
      childId: CHILD_ID,
      method: "credit_card",
      jurisdiction: "US",
    });

    const grantRes = await app.inject({
      method: "POST",
      url: `/v1/family/children/${CHILD_ID}/consent`,
      headers: authHeader(app, "fam-1"),
      payload: { method: "credit_card", jurisdiction: "US" },
    });
    expect(grantRes.statusCode).toBe(201);

    // 2. Subsequent write now has active consent and succeeds (200)
    prismaMock.consentRecord.findFirst.mockResolvedValue({
      id: "consent-fresh",
      childId: CHILD_ID,
      jurisdiction: "US",
      revokedAt: null,
      expiresAt: null,
    });
    prismaMock.ruleSet.upsert.mockResolvedValue({
      childId: CHILD_ID,
      dailyLimitMinutes: 120,
      weekendLimitMinutes: 180,
      bedtimeStart: "21:00",
      bedtimeEnd: "07:00",
      schoolHours: { start: "08:00", end: "15:00", days: [1, 2, 3, 4, 5] },
      blockedCategories: [],
      allowedDomains: [],
      blockedDomains: [],
      safeSearchEnforced: true,
      youtubeRestrictedMode: "strict",
      bonusMinutesToday: 0,
      appRules: [],
      routines: [],
      alwaysAllowedApps: [],
      socialMonitoring: {},
      contactAllowlist: [],
    });
    prismaMock.device.findMany.mockResolvedValue([]);

    const writeRes = await app.inject({
      method: "PUT",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app, "fam-1"),
      payload: {
        screenTime: {
          dailyLimitMinutes: 120,
          weekendLimitMinutes: 180,
          bedtimeStart: "21:00",
          bedtimeEnd: "07:00",
          schoolHours: { start: "08:00", end: "15:00", days: [1, 2, 3, 4, 5] },
        },
        webFilter: {
          blockedCategories: [],
          allowedDomains: [],
          blockedDomains: [],
          safeSearchEnforced: true,
        },
        appRules: [],
        routines: [],
      },
    });

    expect(writeRes.statusCode).toBe(200);
    await app.close();
  });
});
