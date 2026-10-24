import { beforeEach, describe, expect, it, vi } from "vitest";
import { reportsRoutes } from "../src/routes/reports.js";
import { digestRoutes } from "../src/routes/digests.js";
import { deviceRoutes } from "../src/routes/devices.js";
import { MockRedis, authHeader, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const CHILD = { id: "child-1", familyId: "fam-1", displayName: "Laila", birthYear: 2012 };
const FOREIGN_CHILD = { id: "child-9", familyId: "fam-2", displayName: "Omar" };
const DEVICE = { id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } };
const PARENT = { id: "parent-1", familyId: "fam-1", email: "mom@example.com" };

const NOW = Date.now();
const minutesAgo = (m: number) => new Date(NOW - m * 60_000).toISOString();

/** Canned window: 60 app minutes total, 3 urls (2 blocked), 2 calls, 1 sms. */
const CANNED_EVENTS = [
  { id: "e1", childId: "child-1", type: "app_usage", ts: new Date(NOW - 60_000), payload: { app: "TikTok", minutes: 30 } },
  { id: "e2", childId: "child-1", type: "app_usage", ts: new Date(NOW - 120_000), payload: { app: "YouTube", minutes: 20 } },
  { id: "e3", childId: "child-1", type: "app_usage", ts: new Date(NOW - 180_000), payload: { app: "TikTok", minutes: 10 } },
  { id: "e4", childId: "child-1", type: "url", ts: new Date(NOW - 240_000), payload: { domain: "tiktok.com", blocked: false } },
  { id: "e5", childId: "child-1", type: "url", ts: new Date(NOW - 300_000), payload: { domain: "bad.example", blocked: true } },
  { id: "e6", childId: "child-1", type: "url", ts: new Date(NOW - 360_000), payload: { domain: "bad.example", blocked: true } },
  { id: "e7", childId: "child-1", type: "call", ts: new Date(NOW - 420_000), payload: { number: "+20..." } },
  { id: "e8", childId: "child-1", type: "call", ts: new Date(NOW - 480_000), payload: { number: "+20..." } },
  { id: "e9", childId: "child-1", type: "sms", ts: new Date(NOW - 540_000), payload: { number: "+20..." } },
  // Stale event outside the 7-day window must be excluded from aggregation.
  { id: "e10", childId: "child-1", type: "app_usage", ts: new Date(NOW - 20 * 86_400_000), payload: { app: "Stale", minutes: 500 } },
];

/** 12 distinct apps with descending minutes, to prove the top-8 cap and ordering. */
const TOP_APPS_EVENTS = Array.from({ length: 12 }, (_, i) => ({
  id: `a${i}`,
  childId: "child-1",
  type: "app_usage",
  ts: new Date(NOW - i * 60_000),
  payload: { app: `App${i}`, minutes: (12 - i) * 10 },
}));

const familyPublishes = () =>
  MockRedis.instances.flatMap((r) => r.publish.mock.calls).filter(
    ([channel]) => channel === "family:fam-1:events",
  );

/** Prisma-mock findMany that honors the ts.gte window like the real query would. */
function mockActivityFindMany(events: Array<{ ts: Date }>) {
  prismaMock.activityEvent.findMany.mockImplementation(
    async (args: { where?: { ts?: { gte?: Date } } }) => {
      const gte = args?.where?.ts?.gte?.getTime();
      return gte === undefined ? events : events.filter((e) => e.ts.getTime() >= gte);
    },
  );
}

beforeEach(() => {
  resetPrismaMock();
  // Publish events now go through the shared lazy singleton (review API-4 fix),
  // so reset call history instead of dropping the instance registry.
  for (const r of MockRedis.instances) r.publish.mockClear();
});

describe("GET /v1/reports/summary", () => {
  it("aggregates window activity: totals, top apps, urls, blocked domains, calls, sms (#4)", async () => {
    const app = await buildApp(reportsRoutes, "/v1/reports");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    mockActivityFindMany(CANNED_EVENTS);
    prismaMock.socialEvent.count.mockResolvedValue(4);

    const res = await app.inject({
      method: "GET",
      url: "/v1/reports/summary?childId=child-1&days=7",
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.totalAppMinutes).toBe(60);
    expect(body.topApps).toEqual([
      { name: "TikTok", minutes: 40 },
      { name: "YouTube", minutes: 20 },
    ]);
    expect(body.urlVisits).toBe(3);
    expect(body.topBlockedDomains).toEqual([{ domain: "bad.example", count: 2 }]);
    expect(body.socialConcerns).toBe(4);
    expect(body.calls).toBe(2);
    expect(body.sms).toBe(1);
    expect(prismaMock.activityEvent.findMany).toHaveBeenCalledWith(
      expect.objectContaining({ where: expect.objectContaining({ childId: "child-1" }) }),
    );
    await app.close();
  });

  it("caps top apps and blocked domains at 8, sorted by minutes/count desc", async () => {
    const app = await buildApp(reportsRoutes, "/v1/reports");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    mockActivityFindMany(TOP_APPS_EVENTS);
    prismaMock.socialEvent.count.mockResolvedValue(0);

    const res = await app.inject({
      method: "GET",
      url: "/v1/reports/summary?childId=child-1",
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.topApps).toHaveLength(8);
    expect(body.topApps[0]).toEqual({ name: "App0", minutes: 120 });
    expect(body.topApps[7]).toEqual({ name: "App7", minutes: 50 });
    expect(body.totalAppMinutes).toBe(780);
    await app.close();
  });

  it("rejects 401 without a token and 403 for a foreign child", async () => {
    const app = await buildApp(reportsRoutes, "/v1/reports");

    const unauthenticated = await app.inject({ method: "GET", url: "/v1/reports/summary?childId=child-1" });
    expect(unauthenticated.statusCode).toBe(401);
    expect(prismaMock.activityEvent.findMany).not.toHaveBeenCalled();

    prismaMock.child.findUnique.mockResolvedValue(FOREIGN_CHILD);
    const foreign = await app.inject({
      method: "GET",
      url: "/v1/reports/summary?childId=child-9",
      headers: authHeader(app),
    });
    expect(foreign.statusCode).toBe(403);
    expect(prismaMock.activityEvent.findMany).not.toHaveBeenCalled();
    await app.close();
  });

  it("rejects a non-parent (device) token with 403", async () => {
    const app = await buildApp(reportsRoutes, "/v1/reports");
    const res = await app.inject({
      method: "GET",
      url: "/v1/reports/summary?childId=child-1",
      headers: deviceHeader(app),
    });
    expect(res.statusCode).toBe(403);
    expect(prismaMock.activityEvent.findMany).not.toHaveBeenCalled();
    await app.close();
  });
});

describe("GET /v1/reports/wellbeing/:childId (#28)", () => {
  function mockWellbeing(totalMinutes: number, socialConcerns: number, blockedHits: number, dailyLimit: number) {
    prismaMock.child.findUnique.mockResolvedValue({ ...CHILD, ruleSet: { dailyLimitMinutes: dailyLimit } });
    const usageEvents = [];
    let remaining = totalMinutes;
    for (let i = 0; remaining > 0; i++) {
      const minutes = Math.min(30, remaining);
      usageEvents.push({
        id: `w${i}`,
        childId: "child-1",
        type: "app_usage",
        ts: new Date(NOW - i * 60_000),
        payload: { app: "App", minutes },
      });
      remaining -= minutes;
    }
    const events = [
      ...usageEvents,
      ...Array.from({ length: blockedHits }, (_, i) => ({
        id: `b${i}`,
        childId: "child-1",
        type: "url",
        ts: new Date(NOW - i * 60_000),
        payload: { domain: "bad.example", blocked: true },
      })),
    ];
    mockActivityFindMany(events);
    prismaMock.socialEvent.count.mockResolvedValue(socialConcerns);
  }

  it("scores 100 for a light week and floors at 0 for a heavy one", async () => {
    const app = await buildApp(reportsRoutes, "/v1/reports");

    // Light: 315 min of 1260 allowed (25%) → no usage penalty; 0 social; 0 blocked → 100.
    mockWellbeing(315, 0, 0, 180);
    const light = await app.inject({
      method: "GET",
      url: "/v1/reports/wellbeing/child-1?week=2026-W37",
      headers: authHeader(app),
    });
    expect(light.statusCode).toBe(200);
    expect(light.json()).toMatchObject({
      childId: "child-1",
      week: "2026-W37",
      score: 100,
      breakdown: { usage: 0, social: 0, safety: 0 },
    });

    // Heavy: 2520 min of 1260 (ratio 2) → usage 30*1.5*2=90; 1 concern → 5; 2 hits → 6; total 101 → floor 0.
    mockWellbeing(2520, 1, 2, 180);
    const heavy = await app.inject({
      method: "GET",
      url: "/v1/reports/wellbeing/child-1?week=2026-W37",
      headers: authHeader(app),
    });
    expect(heavy.statusCode).toBe(200);
    expect(heavy.json().score).toBe(0);
    expect(heavy.json().breakdown).toEqual({ usage: 90, social: 5, safety: 6 });
    await app.close();
  });

  it("is deterministic: same activity, same score; formula matches the spec exactly", async () => {
    const app = await buildApp(reportsRoutes, "/v1/reports");
    // 1890/1260 = ratio 1.5 → usage 30*1*2=60; 2 concerns → 10; 1 hit → 3 → 100-73=27.
    mockWellbeing(1890, 2, 1, 180);

    const first = await app.inject({
      method: "GET",
      url: "/v1/reports/wellbeing/child-1?week=2026-W37",
      headers: authHeader(app),
    });
    const second = await app.inject({
      method: "GET",
      url: "/v1/reports/wellbeing/child-1?week=2026-W37",
      headers: authHeader(app),
    });
    expect(first.json()).toEqual(second.json());
    expect(first.json().score).toBe(27);
    expect(first.json().breakdown).toEqual({ usage: 60, social: 10, safety: 3 });
    await app.close();
  });

  it("stays within 0-100 and defaults the week label when omitted", async () => {
    const app = await buildApp(reportsRoutes, "/v1/reports");
    mockWellbeing(1260, 3, 5, 180);

    const res = await app.inject({
      method: "GET",
      url: "/v1/reports/wellbeing/child-1",
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().score).toBeGreaterThanOrEqual(0);
    expect(res.json().score).toBeLessThanOrEqual(100);
    expect(res.json().week).toMatch(/^\d{4}-W\d{2}$/);
    await app.close();
  });

  it("rejects 403 for a foreign child and 400 for a malformed week", async () => {
    const app = await buildApp(reportsRoutes, "/v1/reports");
    prismaMock.child.findUnique.mockResolvedValue(FOREIGN_CHILD);
    const foreign = await app.inject({
      method: "GET",
      url: "/v1/reports/wellbeing/child-9",
      headers: authHeader(app),
    });
    expect(foreign.statusCode).toBe(403);

    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    const badWeek = await app.inject({
      method: "GET",
      url: "/v1/reports/wellbeing/child-1?week=september",
      headers: authHeader(app),
    });
    expect(badWeek.statusCode).toBe(400);
    await app.close();
  });
});

describe("digest prefs (#5)", () => {
  it("returns all-true defaults with the parent email when no row exists", async () => {
    const app = await buildApp(digestRoutes, "/v1/digests");
    prismaMock.digestPrefs.findUnique.mockResolvedValue(null);
    prismaMock.parent.findUnique.mockResolvedValue(PARENT);
    prismaMock.parent.findMany.mockResolvedValue([{ email: "mom@example.com" }]);

    const res = await app.inject({ method: "GET", url: "/v1/digests/prefs", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({
      familyId: "fam-1",
      dailyEmail: true,
      weeklyEmail: true,
      pushEnabled: true,
      emails: ["mom@example.com"],
      // Roadmap 2.7: a parent's own verified address needs no confirmation.
      recipients: [{ email: "mom@example.com", status: "confirmed" }],
    });
    await app.close();
  });

  it("returns the stored prefs row when one exists", async () => {
    const app = await buildApp(digestRoutes, "/v1/digests");
    prismaMock.digestPrefs.findUnique.mockResolvedValue({
      familyId: "fam-1",
      dailyEmail: false,
      weeklyEmail: true,
      pushEnabled: false,
      emails: ["mom@example.com", "dad@example.com"],
    });
    prismaMock.parent.findMany.mockResolvedValue([{ email: "mom@example.com" }, { email: "dad@example.com" }]);

    const res = await app.inject({ method: "GET", url: "/v1/digests/prefs", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(res.json().dailyEmail).toBe(false);
    expect(res.json().emails).toHaveLength(2);
    expect(res.json().recipients.map((r: { status: string }) => r.status)).toEqual(["confirmed", "confirmed"]);
    expect(prismaMock.parent.findUnique).not.toHaveBeenCalled();
    await app.close();
  });

  it("upserts prefs on PUT and 400s on invalid payloads", async () => {
    const app = await buildApp(digestRoutes, "/v1/digests");
    prismaMock.digestPrefs.upsert.mockResolvedValue({
      familyId: "fam-1",
      dailyEmail: true,
      weeklyEmail: false,
      pushEnabled: true,
      emails: ["dad@example.com"],
    });
    prismaMock.parent.findMany.mockResolvedValue([{ email: "dad@example.com" }]);

    const res = await app.inject({
      method: "PUT",
      url: "/v1/digests/prefs",
      headers: authHeader(app),
      payload: { dailyEmail: true, weeklyEmail: false, pushEnabled: true, emails: ["dad@example.com"] },
    });
    expect(res.statusCode).toBe(200);
    expect(prismaMock.digestPrefs.upsert).toHaveBeenCalledWith({
      where: { familyId: "fam-1" },
      update: { dailyEmail: true, weeklyEmail: false, pushEnabled: true, emails: ["dad@example.com"] },
      create: { familyId: "fam-1", dailyEmail: true, weeklyEmail: false, pushEnabled: true, emails: ["dad@example.com"] },
    });

    const invalid = await app.inject({
      method: "PUT",
      url: "/v1/digests/prefs",
      headers: authHeader(app),
      payload: { dailyEmail: true, weeklyEmail: false, pushEnabled: true, emails: ["not-an-email"] },
    });
    expect(invalid.statusCode).toBe(400);
    await app.close();
  });

  it("rejects 401 without a token and 403 with a device token", async () => {
    const app = await buildApp(digestRoutes, "/v1/digests");

    const unauthenticated = await app.inject({ method: "GET", url: "/v1/digests/prefs" });
    expect(unauthenticated.statusCode).toBe(401);

    const device = await app.inject({ method: "GET", url: "/v1/digests/prefs", headers: deviceHeader(app) });
    expect(device.statusCode).toBe(403);
    expect(prismaMock.digestPrefs.findUnique).not.toHaveBeenCalled();
    await app.close();
  });
});

describe("POST /v1/digests/send-now (#5)", () => {
  it("renders a markdown digest per child with name and summary numbers", async () => {
    const app = await buildApp(digestRoutes, "/v1/digests");
    prismaMock.child.findMany.mockResolvedValue([CHILD]);
    mockActivityFindMany(CANNED_EVENTS);
    prismaMock.socialEvent.count.mockResolvedValue(4);

    const res = await app.inject({ method: "POST", url: "/v1/digests/send-now", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    const { digests } = res.json();
    expect(digests).toHaveLength(1);
    expect(digests[0].childId).toBe("child-1");
    expect(digests[0].displayName).toBe("Laila");
    const markdown = digests[0].markdown as string;
    expect(markdown).toContain("Laila");
    expect(markdown).toContain("60 min");
    expect(markdown).toContain("TikTok 40m");
    expect(markdown).toContain("URL visits: 3");
    expect(markdown).toContain("bad.example (2)");
    expect(markdown).toContain("Social concerns: 4");
    expect(markdown).toContain("Calls: 2, SMS: 1");
    await app.close();
  });

  it("rejects 401 without a token", async () => {
    const app = await buildApp(digestRoutes, "/v1/digests");
    const res = await app.inject({ method: "POST", url: "/v1/digests/send-now" });
    expect(res.statusCode).toBe(401);
    expect(prismaMock.child.findMany).not.toHaveBeenCalled();
    await app.close();
  });
});

describe("live_activity emission on activity ingest (#29)", () => {
  it("publishes a live_activity family event for the latest app_usage event", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/activity",
      headers: deviceHeader(app),
      payload: {
        events: [
          { type: "url", payload: { domain: "example.com" } },
          { type: "app_usage", ts: minutesAgo(2), payload: { app: "TikTok", minutes: 45 } },
          { type: "app_usage", ts: minutesAgo(1), payload: { app: "YouTube", minutes: 60 } },
        ],
      },
    });
    expect(res.statusCode).toBe(202);
    expect(prismaMock.activityEvent.createMany).toHaveBeenCalledTimes(1);

    const live = familyPublishes()
      .map(([, msg]) => JSON.parse(msg as string))
      .filter((e) => e.type === "live_activity");
    expect(live).toHaveLength(1);
    expect(live[0].payload).toEqual({
      childId: "child-1",
      deviceId: "dev-1",
      app: "YouTube",
      minutesToday: 60,
      ts: minutesAgo(1),
    });
    await app.close();
  });

  it("does not publish when the batch has no app_usage events", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/activity",
      headers: deviceHeader(app),
      payload: { events: [{ type: "url", payload: { domain: "example.com" } }] },
    });
    expect(res.statusCode).toBe(202);
    expect(familyPublishes().some(([, msg]) => JSON.parse(msg as string).type === "live_activity")).toBe(false);
    await app.close();
  });
});
