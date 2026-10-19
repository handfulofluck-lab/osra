import { beforeEach, describe, expect, it, vi } from "vitest";
import { deviceRoutes } from "../src/routes/devices.js";
import { familyRoutes } from "../src/routes/family.js";
import { reportsRoutes } from "../src/routes/reports.js";
import { getRedis } from "../src/redis.js";
import {
  CHILD_SCOPED_DELETE_ORDER,
  DEVICE_TOTAL_APP,
  applyRetention,
  bucketEvents,
  rollupDay,
  screenTimeTodayFromDb,
  usageSeries,
  utcDay,
} from "../src/lib/usageModel.js";
import { runUsageRollupDue, rollupHourUtc } from "../src/jobs/usageRollup.js";
import { MockRedis, authHeader, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const DAY = new Date("2026-10-15T00:00:00.000Z");

describe("usage model — bucketing (Phase 2c, ADR-0013)", () => {
  it("sums app_usage minutes per UTC day and app, skipping live heartbeats and zero minutes", () => {
    const { usage, visits } = bucketEvents([
      { ts: "2026-10-15T10:00:00Z", type: "app_usage", payload: { app: "YouTube", minutes: 12 } },
      { ts: "2026-10-15T23:59:00Z", type: "app_usage", payload: { app: "YouTube", minutes: 3 } },
      { ts: "2026-10-16T00:01:00Z", type: "app_usage", payload: { app: "YouTube", minutes: 5 } }, // next UTC day
      { ts: "2026-10-15T10:05:00Z", type: "app_usage", payload: { app: "YouTube", minutes: 99, live: true } },
      { ts: "2026-10-15T10:06:00Z", type: "app_usage", payload: { app: "Roblox", minutes: 0 } },
      { ts: "2026-10-15T10:07:00Z", type: "app_usage", payload: { minutes: 2.6 } },
    ]);
    expect([...usage.values()]).toEqual([
      { day: DAY, app: "YouTube", minutes: 15 },
      { day: new Date("2026-10-16T00:00:00.000Z"), app: "YouTube", minutes: 5 },
      { day: DAY, app: "unknown", minutes: 3 },
    ]);
    expect(visits).toEqual([]);
  });

  it("turns url events into WebVisit rows, deriving the domain from the url when absent", () => {
    const { visits } = bucketEvents([
      { ts: "2026-10-15T10:00:00Z", type: "url", payload: { url: "https://Example.COM/a?b=1", blocked: true, category: "games" } },
      { ts: "2026-10-15T10:01:00Z", type: "url", payload: { domain: "News.Site" } },
      { ts: "2026-10-15T10:02:00Z", type: "url", payload: { url: "not a url" } },
      { ts: "garbage", type: "url", payload: { domain: "dropped.invalid-ts" } },
    ]);
    expect(visits.map((v) => [v.domain, v.blocked, v.category, v.url])).toEqual([
      ["example.com", true, "games", "https://Example.COM/a?b=1"],
      ["news.site", false, "", ""],
      ["unknown", false, "", "not a url"],
    ]);
  });

  it("utcDay is the UTC calendar day regardless of the process time zone", () => {
    expect(utcDay(new Date("2026-10-15T23:30:00+04:00")).toISOString()).toBe("2026-10-15T00:00:00.000Z");
    expect(utcDay(new Date("2026-10-15T20:30:00Z")).toISOString()).toBe("2026-10-15T00:00:00.000Z");
  });
});

describe("usage model — reads and rollup", () => {
  beforeEach(() => resetPrismaMock());

  it("screenTimeTodayFromDb prefers device totals (*) over the per-app sum", async () => {
    prismaMock.appUsageDaily.findMany.mockResolvedValue([
      { app: "YouTube", minutes: 40 },
      { app: DEVICE_TOTAL_APP, minutes: 55 },
      { app: "Roblox", minutes: 30 },
    ]);
    expect(await screenTimeTodayFromDb("child-1")).toBe(55);
    prismaMock.appUsageDaily.findMany.mockResolvedValue([{ app: "YouTube", minutes: 40 }, { app: "Roblox", minutes: 30 }]);
    expect(await screenTimeTodayFromDb("child-1")).toBe(70);
    prismaMock.appUsageDaily.findMany.mockResolvedValue([]);
    expect(await screenTimeTodayFromDb("child-1")).toBe(0);
  });

  it("usageSeries returns one entry per day, zeros for empty days, per-app split sorted desc", async () => {
    const at = new Date("2026-10-16T12:00:00Z");
    prismaMock.appUsageDaily.findMany.mockResolvedValue([
      { day: new Date("2026-10-16T00:00:00Z"), app: "YouTube", minutes: 20, deviceId: "d1" },
      { day: new Date("2026-10-16T00:00:00Z"), app: "Roblox", minutes: 35, deviceId: "d1" },
      { day: new Date("2026-10-16T00:00:00Z"), app: "YouTube", minutes: 5, deviceId: "d2" },
      { day: new Date("2026-10-14T00:00:00Z"), app: DEVICE_TOTAL_APP, minutes: 90, deviceId: "d1" },
      { day: new Date("2026-10-14T00:00:00Z"), app: "YouTube", minutes: 10, deviceId: "d1" },
    ]);
    const series = await usageSeries("child-1", 3, at);
    expect(series.map((d) => d.day)).toEqual(["2026-10-14", "2026-10-15", "2026-10-16"]);
    expect(series[0]).toEqual({ day: "2026-10-14", minutes: 90, apps: [{ app: "YouTube", minutes: 10 }] });
    expect(series[1]).toEqual({ day: "2026-10-15", minutes: 0, apps: [] });
    expect(series[2]).toEqual({ day: "2026-10-16", minutes: 60, apps: [{ app: "Roblox", minutes: 35 }, { app: "YouTube", minutes: 25 }] });
    const where = prismaMock.appUsageDaily.findMany.mock.calls[0][0].where;
    expect(where.day).toEqual({ gte: new Date("2026-10-14T00:00:00Z"), lte: new Date("2026-10-16T00:00:00Z") });
  });

  it("rollupDay recomputes a day's per-app rows from ActivityEvent and OVERWRITES (idempotent)", async () => {
    prismaMock.activityEvent.findMany.mockResolvedValue([
      { childId: "c1", deviceId: "d1", ts: new Date("2026-10-15T09:00:00Z"), type: "app_usage", payload: { app: "YouTube", minutes: 10 } },
      { childId: "c1", deviceId: "d1", ts: new Date("2026-10-15T10:00:00Z"), type: "app_usage", payload: { app: "YouTube", minutes: 7 } },
      { childId: "c1", deviceId: null, ts: new Date("2026-10-15T10:00:00Z"), type: "app_usage", payload: { app: "Roblox", minutes: 4 } },
    ]);
    prismaMock.appUsageDaily.upsert.mockResolvedValue({});
    const written = await rollupDay(DAY);
    expect(written).toBe(2);
    const where = prismaMock.activityEvent.findMany.mock.calls[0][0].where;
    expect(where).toEqual({ type: "app_usage", ts: { gte: DAY, lt: new Date("2026-10-16T00:00:00.000Z") } });
    const calls = prismaMock.appUsageDaily.upsert.mock.calls.map((c) => c[0]);
    expect(calls).toContainEqual({
      where: { childId_deviceId_day_app: { childId: "c1", deviceId: "d1", day: DAY, app: "YouTube" } },
      create: { childId: "c1", deviceId: "d1", day: DAY, app: "YouTube", minutes: 17 },
      update: { minutes: 17 }, // set, not increment
    });
    expect(calls).toContainEqual(expect.objectContaining({ where: { childId_deviceId_day_app: { childId: "c1", deviceId: "", day: DAY, app: "Roblox" } } }));
  });

  it("applyRetention deletes raw rows older than RETENTION_DAYS and rollups older than ROLLUP_RETENTION_DAYS, binding the instant from JS", async () => {
    for (const m of ["activityEvent", "webVisit", "socialEvent", "locationPing", "appUsageDaily"] as const) {
      prismaMock[m].deleteMany.mockResolvedValue({ count: 2 });
    }
    const now = new Date("2026-10-16T02:00:00Z");
    const out = await applyRetention(now, { RETENTION_DAYS: "90", ROLLUP_RETENTION_DAYS: "365" } as NodeJS.ProcessEnv);
    expect(out).toEqual({ activityEvents: 2, webVisits: 2, socialEvents: 2, locationPings: 2, usageDays: 2 });
    const rawCutoff = new Date(now.getTime() - 90 * 86_400_000);
    expect(prismaMock.activityEvent.deleteMany).toHaveBeenCalledWith({ where: { ts: { lt: rawCutoff } } });
    expect(prismaMock.webVisit.deleteMany).toHaveBeenCalledWith({ where: { ts: { lt: rawCutoff } } });
    expect(prismaMock.socialEvent.deleteMany).toHaveBeenCalledWith({ where: { createdAt: { lt: rawCutoff } } });
    expect(prismaMock.locationPing.deleteMany).toHaveBeenCalledWith({ where: { timestamp: { lt: rawCutoff } } });
    expect(prismaMock.appUsageDaily.deleteMany).toHaveBeenCalledWith({ where: { day: { lt: new Date("2025-10-16T00:00:00.000Z") } } });
    // A too-short window is refused (never below 7 days), and rollups never outlive-less than raw.
    const guard = await applyRetention(now, { RETENTION_DAYS: "1", ROLLUP_RETENTION_DAYS: "3" } as NodeJS.ProcessEnv);
    expect(guard.activityEvents).toBe(2);
    expect(prismaMock.activityEvent.deleteMany).toHaveBeenLastCalledWith({ where: { ts: { lt: rawCutoff } } });
  });

  it("the erasure list covers every child-scoped model that exists in the schema", () => {
    // If a child-scoped model is added to prisma/schema.prisma this list must grow with it.
    expect([...CHILD_SCOPED_DELETE_ORDER]).toEqual([
      "deviceCommand", "deviceApp", "locationPing", "alert", "activityEvent", "socialEvent", "installRequest",
      "webVisit", "appUsageDaily", "device", "ruleSet", "geofence", "consentRecord", "child",
    ]);
  });
});

describe("usage rollup scheduler", () => {
  beforeEach(() => resetPrismaMock());

  it("runs only at the configured UTC hour, claims the day once via SET NX, rolls up YESTERDAY", async () => {
    const redis = getRedis() as unknown as MockRedis;
    prismaMock.activityEvent.findMany.mockResolvedValue([]);
    for (const m of ["activityEvent", "webVisit", "socialEvent", "locationPing", "appUsageDaily"] as const) {
      prismaMock[m].deleteMany.mockResolvedValue({ count: 0 });
    }
    expect(rollupHourUtc({ ROLLUP_HOUR_UTC: "2" } as NodeJS.ProcessEnv)).toBe(2);
    expect(rollupHourUtc({ ROLLUP_HOUR_UTC: "99" } as NodeJS.ProcessEnv)).toBe(2);

    expect(await runUsageRollupDue(new Date("2026-10-16T03:10:00Z"), { ROLLUP_HOUR_UTC: "2" } as NodeJS.ProcessEnv)).toBeNull();

    redis.set.mockResolvedValueOnce("OK");
    const run = await runUsageRollupDue(new Date("2026-10-16T02:10:00Z"), { ROLLUP_HOUR_UTC: "2" } as NodeJS.ProcessEnv);
    expect(run?.day).toBe("2026-10-15");
    expect(redis.set).toHaveBeenCalledWith("jobs:usage-rollup:2026-10-15", expect.any(String), "EX", 36 * 3600, "NX");

    redis.set.mockResolvedValueOnce(null); // another instance already claimed it
    expect(await runUsageRollupDue(new Date("2026-10-16T02:20:00Z"), { ROLLUP_HOUR_UTC: "2" } as NodeJS.ProcessEnv)).toBeNull();
  });
});

describe("usage model — ingestion hooks and routes", () => {
  beforeEach(() => {
    resetPrismaMock();
    const redis = getRedis() as unknown as MockRedis;
    redis.get.mockResolvedValue(null);
  });

  it("POST /devices/:id/activity folds the batch into AppUsageDaily and WebVisit; a rollup failure does not reject the batch", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } });
    prismaMock.activityEvent.createMany.mockResolvedValue({ count: 2 });
    prismaMock.appUsageDaily.upsert.mockResolvedValue({});
    prismaMock.webVisit.createMany.mockResolvedValue({ count: 1 });
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/activity",
      headers: deviceHeader(app),
      payload: { events: [
        { ts: "2026-10-15T10:00:00Z", type: "app_usage", payload: { app: "YouTube", minutes: 12 } },
        { ts: "2026-10-15T10:01:00Z", type: "url", payload: { url: "https://example.com/x", blocked: true } },
        { ts: "2026-10-15T10:02:00Z", type: "app_usage", payload: { app: "YouTube", minutes: 1, live: true } },
      ] },
    });
    expect(res.statusCode).toBe(202);
    expect(prismaMock.appUsageDaily.upsert).toHaveBeenCalledWith({
      where: { childId_deviceId_day_app: { childId: "child-1", deviceId: "dev-1", day: DAY, app: "YouTube" } },
      create: { childId: "child-1", deviceId: "dev-1", day: DAY, app: "YouTube", minutes: 12 },
      update: { minutes: { increment: 12 } },
    });
    expect(prismaMock.webVisit.createMany).toHaveBeenCalledWith({
      data: [{ childId: "child-1", deviceId: "dev-1", ts: new Date("2026-10-15T10:01:00Z"), domain: "example.com", url: "https://example.com/x", blocked: true, category: "" }],
    });

    prismaMock.appUsageDaily.upsert.mockRejectedValueOnce(new Error("db down"));
    const again = await app.inject({ method: "POST", url: "/v1/devices/dev-1/activity", headers: deviceHeader(app), payload: { events: [{ type: "app_usage", payload: { app: "X", minutes: 1 } }] } });
    expect(again.statusCode).toBe(202);
    await app.close();
  });

  it("POST /devices/:id/telemetry writes the device day total (*) alongside the Redis counter", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } });
    prismaMock.device.update.mockResolvedValue({});
    prismaMock.appUsageDaily.upsert.mockResolvedValue({});
    const res = await app.inject({ method: "POST", url: "/v1/devices/dev-1/telemetry", headers: deviceHeader(app), payload: { totalMinutes: 25, batteryPct: 50 } });
    expect(res.statusCode).toBe(202);
    expect(prismaMock.appUsageDaily.upsert).toHaveBeenCalledWith(expect.objectContaining({
      where: { childId_deviceId_day_app: { childId: "child-1", deviceId: "dev-1", day: utcDay(), app: DEVICE_TOTAL_APP } },
      update: { minutes: { increment: 25 } },
    }));
    await app.close();
  });

  it("GET /family/me falls back to the durable day total when the Redis usage key is gone", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.family.findUnique.mockResolvedValue({
      id: "fam-1", name: "F", region: "US",
      parents: [{ id: "parent-1", email: "p@x", displayName: "P", role: "owner", passwordHash: "h" }],
      children: [{ id: "child-1", familyId: "fam-1", displayName: "C", birthYear: 2015, devices: [] }],
    });
    prismaMock.appUsageDaily.findMany.mockResolvedValue([{ app: DEVICE_TOTAL_APP, minutes: 47 }]);
    const res = await app.inject({ method: "GET", url: "/v1/family/me", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(res.json().children[0].screenTimeTodayMinutes).toBe(47);
    await app.close();
  });

  it("#66 GET /family/me takes the LARGER of the Redis counter and the durable total (presence is not authority)", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.family.findUnique.mockResolvedValue({
      id: "fam-1", name: "F", region: "US",
      parents: [{ id: "parent-1", email: "p@x", displayName: "P", role: "owner", passwordHash: "h" }],
      children: [{ id: "child-1", familyId: "fam-1", displayName: "C", birthYear: 2015, devices: [] }],
    });
    const redis = getRedis() as unknown as MockRedis;
    // After a flush, one +5 delta recreated the counter; the table still holds the day's 19.
    redis.get.mockImplementation(async (k: string) => (k.startsWith("usage:child:") ? "5" : null));
    prismaMock.appUsageDaily.findMany.mockResolvedValue([{ app: DEVICE_TOTAL_APP, minutes: 19 }]);
    let res = await app.inject({ method: "GET", url: "/v1/family/me", headers: authHeader(app) });
    expect(res.json().children[0].screenTimeTodayMinutes).toBe(19);
    // The other direction: a rollup write failed, so the cache is ahead of the table.
    redis.get.mockImplementation(async (k: string) => (k.startsWith("usage:child:") ? "23" : null));
    res = await app.inject({ method: "GET", url: "/v1/family/me", headers: authHeader(app) });
    expect(res.json().children[0].screenTimeTodayMinutes).toBe(23);
    await app.close();
  });

  it("GET /reports/usage and /reports/web are family-scoped and validated", async () => {
    const app = await buildApp(reportsRoutes, "/v1/reports");
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    prismaMock.appUsageDaily.findMany.mockResolvedValue([{ day: utcDay(), app: "YouTube", minutes: 9, deviceId: "d" }]);
    prismaMock.webVisit.findMany.mockResolvedValue([{ id: "w1", domain: "example.com", blocked: true, ts: new Date() }]);

    const usage = await app.inject({ method: "GET", url: "/v1/reports/usage?childId=child-1&days=2", headers: authHeader(app) });
    expect(usage.statusCode).toBe(200);
    expect(usage.json().series).toHaveLength(2);
    expect(usage.json().totalMinutes).toBe(9);

    const web = await app.inject({ method: "GET", url: "/v1/reports/web?childId=child-1&blocked=true&domain=Example.com", headers: authHeader(app) });
    expect(web.statusCode).toBe(200);
    expect(web.json().items).toHaveLength(1);
    expect(prismaMock.webVisit.findMany.mock.calls[0][0].where).toMatchObject({ childId: "child-1", blocked: true, domain: "example.com" });

    // Other family → 403; out-of-range days → 400.
    const other = await app.inject({ method: "GET", url: "/v1/reports/usage?childId=child-1", headers: authHeader(app, "fam-2") });
    expect(other.statusCode).toBe(403);
    const bad = await app.inject({ method: "GET", url: "/v1/reports/usage?childId=child-1&days=400", headers: authHeader(app) });
    expect(bad.statusCode).toBe(400);
    const badWeb = await app.inject({ method: "GET", url: "/v1/reports/web?childId=child-1&days=91", headers: authHeader(app) });
    expect(badWeb.statusCode).toBe(400);
    await app.close();
  });
});
