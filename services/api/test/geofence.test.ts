import { beforeEach, describe, expect, it, vi } from "vitest";
import { createHmac } from "node:crypto";
import { signV2 } from "../src/lib/internalAuth.js";
import { haversineMeters, isInsideFence } from "../src/lib/geo.js";
import { locationRoutes } from "../src/routes/location.js";
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

const CHILD_ID = "child-1";
const DEVICE_ID = "device-1";
const HOME_FENCE = {
  id: "fence-1",
  childId: CHILD_ID,
  label: "Home",
  lat: 40.7128,
  lng: -74.006,
  radiusM: 150,
  notifyOnEnter: true,
  notifyOnExit: true,
};

/** Flat Prisma RuleSet row as the findUnique mock would return it. */
function flatRuleSet() {
  return {
    id: "rs-1",
    childId: CHILD_ID,
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
    routines: [{ id: "routine-school", name: "School" }],
    alwaysAllowedApps: [],
    bonusMinutesToday: 0,
    socialMonitoring: {},
    contactAllowlist: [],
    updatedAt: "2026-09-16T00:00:00.000Z",
  };
}

function wireRedis(): MockRedis {
  const redis = getRedis() as unknown as MockRedis;
  redis.publish.mockResolvedValue(1);
  redis.lpush.mockResolvedValue(1);
  redis.ltrim.mockResolvedValue("OK");
  return redis;
}

describe("haversineMeters", () => {
  it("returns 0 for identical coordinates", () => {
    expect(haversineMeters(40.7128, -74.006, 40.7128, -74.006)).toBe(0);
  });

  it("matches known distances", () => {
    // One degree of longitude at the equator is ~111.19 km (R = 6371000 m).
    expect(haversineMeters(0, 0, 0, 1)).toBeCloseTo(111194.9, 0);
    // New York to a point 1 degree east at the same latitude.
    expect(haversineMeters(40.7128, -74.006, 40.7128, -73.006)).toBeCloseTo(84284, -1);
  });

  it("classifies inside/outside a circular fence", () => {
    expect(isInsideFence(40.7128, -74.006, HOME_FENCE)).toBe(true); // center
    expect(isInsideFence(40.7135, -74.006, HOME_FENCE)).toBe(true); // ~78 m north
    expect(isInsideFence(40.72, -74.006, HOME_FENCE)).toBe(false); // ~800 m away
  });
});

describe("geofence transitions on POST /v1/location/ping", () => {
  beforeEach(() => {
    resetPrismaMock();
    prismaMock.device.findUnique.mockResolvedValue({ id: DEVICE_ID, childId: CHILD_ID });
  });

  function setupApp() {
    return buildApp(locationRoutes, "/v1/location");
  }

  it("raises a geofence alert when the child enters a fence", async () => {
    const app = await setupApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.geofence.findMany.mockResolvedValue([HOME_FENCE]);
    // Previous ping was outside the fence (~1 km away).
    prismaMock.locationPing.findFirst.mockResolvedValue({ lat: 40.72, lng: -74.006 });
    prismaMock.locationPing.create.mockResolvedValue({ id: "ping-2" });
    prismaMock.alert.create.mockResolvedValue({ id: "alert-1" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: authHeader(app),
      payload: { childId: CHILD_ID, deviceId: DEVICE_ID, lat: 40.7128, lng: -74.006, accuracyM: 5 },
    });
    expect(res.statusCode).toBe(201);
    expect(prismaMock.alert.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({ category: "geofence", title: "Entered Home" }),
      }),
    );
    // Issue #242 review: the alert must name the fence only. A geofence alert is not deleted by the
    // retention job, so coordinates here would outlive the 30-day location window.
    const enterData = prismaMock.alert.create.mock.calls[0][0].data as { metadata: Record<string, unknown> };
    expect(enterData.metadata).toEqual({ geofenceId: HOME_FENCE.id, label: HOME_FENCE.label });
    expect(enterData.metadata).not.toHaveProperty("lat");
    expect(enterData.metadata).not.toHaveProperty("lng");
    await app.close();
  });

  it("raises a geofence alert when the child exits a fence", async () => {
    const app = await setupApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.geofence.findMany.mockResolvedValue([HOME_FENCE]);
    // Previous ping was inside the fence; the new one is far outside.
    prismaMock.locationPing.findFirst.mockResolvedValue({ lat: 40.7128, lng: -74.006 });
    prismaMock.locationPing.create.mockResolvedValue({ id: "ping-2" });
    prismaMock.alert.create.mockResolvedValue({ id: "alert-1" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: authHeader(app),
      payload: { childId: CHILD_ID, deviceId: DEVICE_ID, lat: 40.72, lng: -74.006, accuracyM: 5 },
    });
    expect(res.statusCode).toBe(201);
    expect(prismaMock.alert.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({ category: "geofence", title: "Left Home" }),
      }),
    );
    const exitData = prismaMock.alert.create.mock.calls[0][0].data as { metadata: Record<string, unknown> };
    expect(exitData.metadata).toEqual({ geofenceId: HOME_FENCE.id, label: HOME_FENCE.label });
    expect(exitData.metadata).not.toHaveProperty("lat");
    expect(exitData.metadata).not.toHaveProperty("lng");
    await app.close();
  });

  it("does not alert when notifyOnExit is disabled or there is no transition", async () => {
    const app = await setupApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.geofence.findMany.mockResolvedValue([{ ...HOME_FENCE, notifyOnExit: false }]);
    prismaMock.locationPing.findFirst.mockResolvedValue({ lat: 40.7128, lng: -74.006 }); // inside
    prismaMock.locationPing.create.mockResolvedValue({ id: "ping-2" });

    // Inside -> outside, but notifyOnExit=false.
    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: authHeader(app),
      payload: { childId: CHILD_ID, deviceId: DEVICE_ID, lat: 40.72, lng: -74.006, accuracyM: 5 },
    });
    expect(res.statusCode).toBe(201);
    expect(prismaMock.alert.create).not.toHaveBeenCalled();

    // No transition (was outside, still outside) with notifyOnEnter/Exit=true.
    prismaMock.geofence.findMany.mockResolvedValue([HOME_FENCE]);
    prismaMock.locationPing.findFirst.mockResolvedValue({ lat: 40.72, lng: -74.006 });
    const res2 = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: authHeader(app),
      payload: { childId: CHILD_ID, deviceId: DEVICE_ID, lat: 40.721, lng: -74.006, accuracyM: 5 },
    });
    expect(res2.statusCode).toBe(201);
    expect(prismaMock.alert.create).not.toHaveBeenCalled();
    await app.close();
  });
});

describe("geofence baseline and stale-gap rule (issue #243)", () => {
  // Claude's decision on #243: keep deriving the transition from pings, but a first ping after a
  // hole is a baseline (no alert, no routine nudge), and a comparison more than 6 h stale says so
  // in the alert. A tight fence at the fence centre, punched in the same coordinates as the
  // existing tests.
  const OUTSIDE = { lat: 40.72, lng: -74.006 };
  const INSIDE = { lat: 40.7128, lng: -74.006 };

  function pingBody(lat: number, lng: number, timestamp?: string) {
    return { childId: CHILD_ID, deviceId: DEVICE_ID, lat, lng, accuracyM: 5, ...(timestamp ? { timestamp } : {}) };
  }

  beforeEach(() => {
    resetPrismaMock();
    // The MockRedis instance is shared across the file and `resetPrismaMock` does not touch it, so
    // clear its call history or an earlier test's publish reads as this test's.
    wireRedis().publish.mockClear();
    prismaMock.device.findUnique.mockResolvedValue({ id: DEVICE_ID, childId: CHILD_ID });
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.locationPing.create.mockResolvedValue({ id: "ping-new" });
    prismaMock.alert.create.mockResolvedValue({ id: "alert-1" });
  });

  it("treats the first ping after a retention hole as a baseline — no alert and no routine nudge", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    // A routine is bound to the fence: entering would publish the ruleset and queue rules_updated.
    prismaMock.geofence.findMany.mockResolvedValue([{ ...HOME_FENCE, routineId: "routine-school" }]);
    // No previous ping: first ping ever, or retention deleted the history (the 30-day window).
    prismaMock.locationPing.findFirst.mockResolvedValue(null);

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: authHeader(app),
      payload: pingBody(INSIDE.lat, INSIDE.lng),
    });
    expect(res.statusCode).toBe(201);
    expect(prismaMock.alert.create).not.toHaveBeenCalled();
    // Feature #23's routine nudge is an enter action too: a baseline must not fire it.
    expect(prismaMock.ruleSet.findUnique).not.toHaveBeenCalled();
    expect(prismaMock.device.findMany).not.toHaveBeenCalled();
    expect(prismaMock.deviceCommand.create).not.toHaveBeenCalled();
    expect((getRedis() as unknown as MockRedis).publish).not.toHaveBeenCalled();
    await app.close();
  });

  it("compares normally when the previous ping is 10 minutes old, with no gap note", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.geofence.findMany.mockResolvedValue([HOME_FENCE]);
    prismaMock.locationPing.findFirst.mockResolvedValue({ ...OUTSIDE, timestamp: new Date("2026-10-20T11:50:00.000Z") });

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: authHeader(app),
      payload: pingBody(INSIDE.lat, INSIDE.lng, "2026-10-20T12:00:00.000Z"),
    });
    expect(res.statusCode).toBe(201);
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);
    const data = prismaMock.alert.create.mock.calls[0][0].data as { title: string; body: string; metadata: Record<string, unknown> };
    expect(data.title).toBe("Entered Home");
    expect(data.body).not.toMatch(/no location/i);
    expect(data.metadata).toEqual({ geofenceId: HOME_FENCE.id, label: HOME_FENCE.label });
    await app.close();
  });

  it("names a 14-hour gap when the previous ping is that old", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.geofence.findMany.mockResolvedValue([HOME_FENCE]);
    prismaMock.locationPing.findFirst.mockResolvedValue({ ...OUTSIDE, timestamp: new Date("2026-10-20T00:00:00.000Z") });

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: authHeader(app),
      payload: pingBody(INSIDE.lat, INSIDE.lng, "2026-10-20T14:00:00.000Z"),
    });
    expect(res.statusCode).toBe(201);
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);
    const data = prismaMock.alert.create.mock.calls[0][0].data as { title: string; body: string; metadata: Record<string, unknown> };
    expect(data.title).toBe("Entered Home");
    expect(data.body).toContain("14 h");
    expect(data.metadata.gapMinutes).toBe(840);
    // F1 from #242 stands: the alert names the gap, never the child's position.
    expect(data.metadata).not.toHaveProperty("lat");
    expect(data.metadata).not.toHaveProperty("lng");
    await app.close();
  });

  it("measures the gap from the earliest ping in the upload, so a buffered batch claims none", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.geofence.findMany.mockResolvedValue([HOME_FENCE]);
    // Previous ping 14 h before the batch's last entry, but only 10 min before its first: the
    // phone was buffering, so there was no quiet period to report.
    prismaMock.locationPing.findFirst.mockResolvedValue({ ...OUTSIDE, timestamp: new Date("2026-10-20T00:00:00.000Z") });

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: authHeader(app),
      payload: {
        childId: CHILD_ID,
        deviceId: DEVICE_ID,
        pings: [
          { lat: OUTSIDE.lat, lng: OUTSIDE.lng, accuracyM: 10, timestamp: "2026-10-20T00:10:00.000Z" },
          { lat: INSIDE.lat, lng: INSIDE.lng, accuracyM: 5, timestamp: "2026-10-20T14:00:00.000Z" },
        ],
      },
    });
    expect(res.statusCode).toBe(201);
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);
    const data = prismaMock.alert.create.mock.calls[0][0].data as { title: string; body: string; metadata: Record<string, unknown> };
    expect(data.title).toBe("Entered Home");
    expect(data.body).not.toMatch(/no location/i);
    expect(data.metadata).not.toHaveProperty("gapMinutes");
    await app.close();
  });
});

describe("school-geofence routine auto-apply (Feature #23)", () => {
  beforeEach(() => {
    resetPrismaMock();
    wireRedis();
    prismaMock.device.findUnique.mockResolvedValue({ id: DEVICE_ID, childId: CHILD_ID });
  });

  it("entering a fence with routineId publishes the ruleset and queues rules_updated", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.geofence.findMany.mockResolvedValue([{ ...HOME_FENCE, routineId: "routine-school" }]);
    // Previous ping was outside the fence; the new one is inside (school arrival).
    prismaMock.locationPing.findFirst.mockResolvedValue({ lat: 40.72, lng: -74.006 });
    prismaMock.locationPing.create.mockResolvedValue({ id: "ping-2" });
    prismaMock.alert.create.mockResolvedValue({ id: "alert-1" });
    prismaMock.ruleSet.findUnique.mockResolvedValue(flatRuleSet());
    prismaMock.device.findMany.mockResolvedValue([{ id: "dev-1" }, { id: "dev-2" }]);

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: authHeader(app),
      payload: { childId: CHILD_ID, deviceId: DEVICE_ID, lat: 40.7128, lng: -74.006, accuracyM: 5 },
    });
    expect(res.statusCode).toBe(201);

    const redis = getRedis() as unknown as MockRedis;
    // The child's ruleset is published for agents to consume.
    expect(redis.publish).toHaveBeenCalledWith(
      `child:${CHILD_ID}:rules`,
      expect.stringContaining(`"childId":"${CHILD_ID}"`),
    );
    // Every device is nudged to re-fetch the rules.
    for (const deviceId of ["dev-1", "dev-2"]) {
      expect(prismaMock.deviceCommand.create).toHaveBeenCalledWith(
        expect.objectContaining({ data: expect.objectContaining({ deviceId, type: "rules_updated", payload: { reason: "geofence_routine" } }) }),
      );
    }
    await app.close();
  });

  it("entering a fence without routineId does not touch rules or devices", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.geofence.findMany.mockResolvedValue([HOME_FENCE]); // no routineId
    prismaMock.locationPing.findFirst.mockResolvedValue({ lat: 40.72, lng: -74.006 });
    prismaMock.locationPing.create.mockResolvedValue({ id: "ping-2" });
    prismaMock.alert.create.mockResolvedValue({ id: "alert-1" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: authHeader(app),
      payload: { childId: CHILD_ID, deviceId: DEVICE_ID, lat: 40.7128, lng: -74.006, accuracyM: 5 },
    });
    expect(res.statusCode).toBe(201);
    expect(prismaMock.ruleSet.findUnique).not.toHaveBeenCalled();
    expect(prismaMock.device.findMany).not.toHaveBeenCalled();
    await app.close();
  });
});

const HMAC_SECRET = "test-internal-secret";
const sign = (raw: string) => createHmac("sha256", HMAC_SECRET).update(raw).digest("hex");

describe("location ping validation & auth", () => {
  beforeEach(() => {
    resetPrismaMock();
    prismaMock.device.findUnique.mockResolvedValue({ id: DEVICE_ID, childId: CHILD_ID });
    process.env.INTERNAL_HMAC_SECRET = HMAC_SECRET;
  });

  it("rejects out-of-range coordinates and bad field types with 400", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    const base = { childId: CHILD_ID, deviceId: DEVICE_ID, accuracyM: 5 };
    const cases: unknown[] = [
      { ...base, lat: 91, lng: -74.006 },
      { ...base, lat: -90.1, lng: -74.006 },
      { ...base, lat: 40.7128, lng: 181 },
      { ...base, lat: 40.7128, lng: -180.5 },
      { ...base, lat: "40.7", lng: -74.006 },
      { ...base, lat: 40.7128, lng: -74.006, accuracyM: -3 },
      { deviceId: DEVICE_ID, lat: 40.7128, lng: -74.006 },
    ];
    for (const payload of cases) {
      const res = await app.inject({
        method: "POST",
        url: "/v1/location/ping",
        headers: authHeader(app),
        payload: payload as Record<string, unknown>,
      });
      expect(res.statusCode).toBe(400);
    }
    expect(prismaMock.locationPing.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("accepts boundary coordinates lat ±90 / lng ±180 (201)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.geofence.findMany.mockResolvedValue([]);
    prismaMock.locationPing.create.mockResolvedValue({ id: "ping-edge" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: authHeader(app),
      payload: { childId: CHILD_ID, deviceId: DEVICE_ID, lat: 90, lng: -180, accuracyM: 0 },
    });
    expect(res.statusCode).toBe(201);
    await app.close();
  });

  it("returns 401 without a JWT or a valid HMAC signature", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      payload: { childId: CHILD_ID, deviceId: DEVICE_ID, lat: 40.7128, lng: -74.006, accuracyM: 5 },
    });
    expect(res.statusCode).toBe(401);

    const badSig = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: { "x-familyshield-signature": "deadbeef" },
      payload: { childId: CHILD_ID, deviceId: DEVICE_ID, lat: 40.7128, lng: -74.006, accuracyM: 5 },
    });
    expect(badSig.statusCode).toBe(401);
    expect(prismaMock.locationPing.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("accepts a correctly HMAC-signed ping without any JWT (201)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.geofence.findMany.mockResolvedValue([]);
    prismaMock.locationPing.create.mockResolvedValue({ id: "ping-hmac" });

    const raw = JSON.stringify({ childId: CHILD_ID, deviceId: DEVICE_ID, lat: 40.7128, lng: -74.006, accuracyM: 5 });
    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: { "content-type": "application/json", ...signV2(HMAC_SECRET, raw, { caller: "ai-engine" }) },
      payload: raw,
    });
    expect(res.statusCode).toBe(201);
    expect(res.json().ping.id).toBe("ping-hmac");
    await app.close();
  });

  it("returns 404 for an unknown child and 403 when the JWT family differs", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue(null);
    const missing = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: authHeader(app),
      payload: { childId: "child-9", deviceId: DEVICE_ID, lat: 40.7128, lng: -74.006, accuracyM: 5 },
    });
    expect(missing.statusCode).toBe(404);
    expect(missing.json().error).toBe("child_not_found");

    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-2" });
    const foreign = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: authHeader(app, "fam-1"),
      payload: { childId: CHILD_ID, deviceId: DEVICE_ID, lat: 40.7128, lng: -74.006, accuracyM: 5 },
    });
    expect(foreign.statusCode).toBe(403);
    expect(prismaMock.locationPing.create).not.toHaveBeenCalled();
    await app.close();
  });
});

describe("location latest & history", () => {
  beforeEach(() => {
    resetPrismaMock();
  });

  it("returns the child's most recent ping (200)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.locationPing.findFirst.mockResolvedValue({ id: "ping-7", lat: 40.7128, lng: -74.006 });

    const res = await app.inject({ method: "GET", url: `/v1/location/${CHILD_ID}/latest`, headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(res.json().latest.id).toBe("ping-7");
    expect(prismaMock.locationPing.findFirst).toHaveBeenCalledWith({
      where: { childId: CHILD_ID },
      orderBy: { timestamp: "desc" },
    });
    await app.close();
  });

  it("returns 404 from /latest when the child has no pings", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.locationPing.findFirst.mockResolvedValue(null);

    const res = await app.inject({ method: "GET", url: `/v1/location/${CHILD_ID}/latest`, headers: authHeader(app) });
    expect(res.statusCode).toBe(404);
    expect(res.json().error).toBe("no_pings");
    await app.close();
  });

  it("returns 403 from /latest for another family's child", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-2" });

    const res = await app.inject({
      method: "GET",
      url: `/v1/location/${CHILD_ID}/latest`,
      headers: authHeader(app, "fam-1"),
    });
    expect(res.statusCode).toBe(403);
    expect(prismaMock.locationPing.findFirst).not.toHaveBeenCalled();
    await app.close();
  });

  it("filters history by the from/to window and caps at 500 rows", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.locationPing.findMany.mockResolvedValue([{ id: "ping-1" }]);

    const from = "2026-09-01T00:00:00.000Z";
    const to = "2026-09-14T23:59:59.000Z";
    const res = await app.inject({
      method: "GET",
      url: `/v1/location/${CHILD_ID}/history?from=${from}&to=${to}`,
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().pings).toHaveLength(1);
    expect(prismaMock.locationPing.findMany).toHaveBeenCalledWith({
      where: { childId: CHILD_ID, timestamp: { gte: new Date(from), lte: new Date(to) } },
      orderBy: { timestamp: "desc" },
      take: 500,
    });
    await app.close();
  });

  it("omits the timestamp filter when no window is given", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.locationPing.findMany.mockResolvedValue([]);

    const res = await app.inject({
      method: "GET",
      url: `/v1/location/${CHILD_ID}/history`,
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(200);
    expect(prismaMock.locationPing.findMany).toHaveBeenCalledWith({
      where: { childId: CHILD_ID },
      orderBy: { timestamp: "desc" },
      take: 500,
    });
    await app.close();
  });

  it("rejects malformed from/to datetimes with 400 (not 500)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });

    for (const query of ["from=not-a-date", "to=yesterday", "from=2026-13-01T00:00:00Z"]) {
      const res = await app.inject({
        method: "GET",
        url: `/v1/location/${CHILD_ID}/history?${query}`,
        headers: authHeader(app),
      });
      expect(res.statusCode).toBe(400);
    }
    expect(prismaMock.locationPing.findMany).not.toHaveBeenCalled();
    await app.close();
  });
});

describe("geofence CRUD", () => {
  beforeEach(() => {
    resetPrismaMock();
  });

  it("lists a child's geofences (200)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.geofence.findMany.mockResolvedValue([HOME_FENCE]);

    const res = await app.inject({ method: "GET", url: `/v1/location/geofences/${CHILD_ID}`, headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(res.json().geofences).toHaveLength(1);
    expect(res.json().geofences[0].label).toBe("Home");
    await app.close();
  });

  it("creates a geofence for a child of the family (201)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.geofence.create.mockResolvedValue(HOME_FENCE);

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/geofences",
      headers: authHeader(app),
      payload: {
        childId: CHILD_ID,
        label: "Home",
        lat: 40.7128,
        lng: -74.006,
        radiusM: 150,
        notifyOnEnter: true,
        notifyOnExit: true,
      },
    });
    expect(res.statusCode).toBe(201);
    expect(res.json().geofence.id).toBe("fence-1");
    expect(prismaMock.geofence.create).toHaveBeenCalledWith({
      data: {
        childId: CHILD_ID,
        label: "Home",
        lat: 40.7128,
        lng: -74.006,
        radiusM: 150,
        notifyOnEnter: true,
        notifyOnExit: true,
      },
    });
    await app.close();
  });

  it("creates a geofence bound to a routine (201, Feature #23)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.geofence.create.mockResolvedValue({ ...HOME_FENCE, id: "fence-school", label: "School", routineId: "routine-school" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/geofences",
      headers: authHeader(app),
      payload: {
        childId: CHILD_ID,
        label: "School",
        lat: 40.7128,
        lng: -74.006,
        radiusM: 200,
        notifyOnEnter: true,
        notifyOnExit: false,
        routineId: "routine-school",
      },
    });
    expect(res.statusCode).toBe(201);
    expect(res.json().geofence.routineId).toBe("routine-school");
    expect(prismaMock.geofence.create).toHaveBeenCalledWith({
      data: expect.objectContaining({ label: "School", routineId: "routine-school" }),
    });
    await app.close();
  });

  it("rejects an invalid geofence body with 400", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    const base = { childId: CHILD_ID, label: "Home", lat: 40.7128, lng: -74.006 };

    const tooSmall = await app.inject({
      method: "POST",
      url: "/v1/location/geofences",
      headers: authHeader(app),
      payload: { ...base, radiusM: 5 }, // below the 10 m minimum
    });
    expect(tooSmall.statusCode).toBe(400);

    const tooBig = await app.inject({
      method: "POST",
      url: "/v1/location/geofences",
      headers: authHeader(app),
      payload: { ...base, radiusM: 100001 },
    });
    expect(tooBig.statusCode).toBe(400);

    const badLat = await app.inject({
      method: "POST",
      url: "/v1/location/geofences",
      headers: authHeader(app),
      payload: { ...base, lat: 91, radiusM: 150 },
    });
    expect(badLat.statusCode).toBe(400);
    expect(prismaMock.geofence.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("rejects geofence creation for another family's child (403) and a missing childId (400)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-2" });
    const foreign = await app.inject({
      method: "POST",
      url: "/v1/location/geofences",
      headers: authHeader(app, "fam-1"),
      payload: { childId: CHILD_ID, label: "Home", lat: 40.7128, lng: -74.006, radiusM: 150 },
    });
    expect(foreign.statusCode).toBe(403);

    const noChild = await app.inject({
      method: "POST",
      url: "/v1/location/geofences",
      headers: authHeader(app),
      payload: { label: "Home", lat: 40.7128, lng: -74.006, radiusM: 150 },
    });
    expect(noChild.statusCode).toBe(400);
    expect(prismaMock.geofence.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("deletes a geofence (200), 404 for an unknown id, 403 for another family's", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.geofence.findUnique.mockResolvedValue({ id: "fence-1", childId: CHILD_ID, child: { familyId: "fam-1" } });
    prismaMock.geofence.delete.mockResolvedValue({ id: "fence-1" });

    const res = await app.inject({ method: "DELETE", url: "/v1/location/geofences/fence-1", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ deleted: true, id: "fence-1" });

    prismaMock.geofence.findUnique.mockResolvedValue(null);
    const missing = await app.inject({ method: "DELETE", url: "/v1/location/geofences/fence-9", headers: authHeader(app) });
    expect(missing.statusCode).toBe(404);

    prismaMock.geofence.findUnique.mockResolvedValue({ id: "fence-1", childId: CHILD_ID, child: { familyId: "fam-2" } });
    const foreign = await app.inject({
      method: "DELETE",
      url: "/v1/location/geofences/fence-1",
      headers: authHeader(app, "fam-1"),
    });
    expect(foreign.statusCode).toBe(403);
    await app.close();
  });

  it("rejects geofence deletion with a device token (403) — parent-only mutation", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    const res = await app.inject({
      method: "DELETE",
      url: "/v1/location/geofences/fence-1",
      headers: deviceHeader(app),
    });
    expect(res.statusCode).toBe(403);
    expect(prismaMock.geofence.findUnique).not.toHaveBeenCalled();
    await app.close();
  });

  it("accepts a batched location ping envelope from a device token deriving identity claims (201) (BUG-001)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    prismaMock.geofence.findMany.mockResolvedValue([]);
    prismaMock.locationPing.create.mockResolvedValue({ id: "ping-batch-1" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: deviceHeader(app),
      payload: {
        pings: [
          { lat: 40.7128, lng: -74.006, accuracyM: 10, timestamp: "2026-10-11T12:00:00Z" },
          { lat: 40.7138, lng: -74.007, accuracyM: 5, timestamp: "2026-10-11T12:01:00Z" },
        ],
      },
    });
    expect(res.statusCode).toBe(201);
    expect(res.json().count).toBe(2);
    expect(res.json().ping).toBeDefined();
    await app.close();
  });

  it("returns 401 device_revoked if device record is not found in database (BUG-001 / FK-500 fix)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    prismaMock.geofence.findMany.mockResolvedValue([]);
    prismaMock.locationPing.create.mockRejectedValue(new Error("Foreign key constraint violated (deviceId does not exist)"));

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: deviceHeader(app),
      payload: { lat: 40.7128, lng: -74.006, accuracyM: 5 },
    });
    expect(res.statusCode).toBe(401);
    expect(res.json().error).toBe("device_revoked");
    await app.close();
  });
});
