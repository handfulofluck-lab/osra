import { beforeEach, describe, expect, it, vi } from "vitest";
import Fastify, { type FastifyInstance } from "fastify";
import fastifyJwt from "@fastify/jwt";
import { familyRoutes } from "../src/routes/family.js";
import { consentRoutes } from "../src/routes/consent.js";
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
  await app.register(consentRoutes, { prefix: "/v1/consent" });
  await app.register(rulesRoutes, { prefix: "/v1/rules" });
  await app.register(deviceRoutes, { prefix: "/v1/devices" });
  await app.register(controlsRoutes, { prefix: "/v1/controls" });
  await app.register(locationRoutes, { prefix: "/v1/location" });
  await app.ready();
  return app;
}

describe("parental consent revocation and gate enforcement (spec §12.5, ADR-0002, Issue #43)", () => {
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

  it("POST /v1/consent/:childId/revoke operates identically (200)", async () => {
    const app = await buildConsentApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1", family: FAMILY });
    prismaMock.consentRecord.updateMany.mockResolvedValue({ count: 1 });

    const res = await app.inject({
      method: "POST",
      url: `/v1/consent/${CHILD_ID}/revoke`,
      headers: authHeader(app, "fam-1"),
    });

    expect(res.statusCode).toBe(200);
    expect(res.json().revoked).toBe(true);
    expect(res.json().count).toBe(1);
    await app.close();
  });

  it("POST /v1/consent/:childId/revoke returns 403 for another family's child", async () => {
    const app = await buildConsentApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-2" });

    const res = await app.inject({
      method: "POST",
      url: `/v1/consent/${CHILD_ID}/revoke`,
      headers: authHeader(app, "fam-1"),
    });

    expect(res.statusCode).toBe(403);
    await app.close();
  });

  it("GET /v1/consent/:childId/status returns active status", async () => {
    const app = await buildConsentApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1", family: FAMILY });
    prismaMock.consentRecord.findFirst.mockResolvedValue({
      id: "c-1",
      childId: CHILD_ID,
      jurisdiction: "US",
      revokedAt: null,
      expiresAt: null,
    });

    const res = await app.inject({
      method: "GET",
      url: `/v1/consent/${CHILD_ID}/status`,
      headers: authHeader(app, "fam-1"),
    });

    expect(res.statusCode).toBe(200);
    expect(res.json().active).toBe(true);
    expect(res.json().jurisdiction).toBe("US");
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
