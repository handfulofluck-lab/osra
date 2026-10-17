import { beforeEach, describe, expect, it, vi } from "vitest";
import Fastify, { type FastifyInstance } from "fastify";
import fastifyJwt from "@fastify/jwt";
import { controlsRoutes } from "../src/routes/controls.js";
import { deviceRoutes } from "../src/routes/devices.js";
import { rulesRoutes } from "../src/routes/rules.js";
import { getRedis } from "../src/redis.js";
import { MockRedis, authHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const CHILD = { id: "child-1", familyId: "fam-1" };
const DEVICES = [{ id: "dev-1" }, { id: "dev-2" }];
const PAUSED_KEY = "child:child-1:internet-paused";

/** In-memory Redis state so pause/status/resume round-trips behave like a real store. */
const store = new Map<string, string>();

function wireRedis(): MockRedis {
  const redis = getRedis() as unknown as MockRedis;
  redis.get.mockImplementation(async (key: string) => store.get(key) ?? null);
  redis.set.mockImplementation(async (key: string, value: unknown) => {
    store.set(key, String(value));
    return "OK";
  });
  redis.del.mockImplementation(async (...keys: string[]) =>
    keys.reduce((n, k) => n + (store.delete(k) ? 1 : 0), 0),
  );
  redis.publish.mockResolvedValue(1);
  redis.lpush.mockResolvedValue(1);
  redis.ltrim.mockResolvedValue("OK");
  return redis;
}

/** Build one app with the device, rules and controls families mounted, mirroring server.ts. */
async function buildFullApp(): Promise<FastifyInstance> {
  const app = Fastify({ logger: false });
  await app.register(fastifyJwt, { secret: "test-secret" });
  await app.register(deviceRoutes, { prefix: "/v1/devices" });
  await app.register(rulesRoutes, { prefix: "/v1/rules" });
  await app.register(controlsRoutes, { prefix: "/v1/controls" });
  await app.ready();
  return app;
}

/** Flat Prisma RuleSet row as the upsert/findUnique mocks would return it. */
function flatRuleSet(bonusMinutesToday = 0) {
  return {
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
    alwaysAllowedApps: ["com.android.chrome"],
    bonusMinutesToday,
    updatedAt: "2026-09-16T00:00:00.000Z",
  };
}

/** Phase 2b: commands are durable rows — assert on the store, not on a Redis list. */
function queuedCommands(): Array<{ deviceId: string; type: string; payload: Record<string, unknown> }> {
  return prismaMock.deviceCommand.create.mock.calls.map(([arg]: [{ data: { deviceId: string; type: string; payload: Record<string, unknown> } }]) => arg.data);
}

describe("controls routes (features #10/#11)", () => {
  beforeEach(() => {
    resetPrismaMock();
    store.clear();
    wireRedis();
  });

  it("pause-internet fans pause_internet out to every device and flips status to paused", async () => {
    const app = await buildFullApp();
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.device.findMany.mockResolvedValue(DEVICES);

    const res = await app.inject({
      method: "POST",
      url: "/v1/controls/children/child-1/pause-internet",
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ childId: "child-1", paused: true });

    const redis = getRedis() as unknown as MockRedis;
    for (const deviceId of ["dev-1", "dev-2"]) {
      expect(redis.publish).toHaveBeenCalledWith(
        `device:${deviceId}:commands`,
        expect.stringContaining('"type":"pause_internet"'),
      );
      expect(queuedCommands()).toContainEqual(expect.objectContaining({ deviceId, type: "pause_internet" }));
    }
    expect(store.get(PAUSED_KEY)).toEqual(expect.stringContaining('"pausedAt"'));

    const status = await app.inject({
      method: "GET",
      url: "/v1/controls/children/child-1/status",
      headers: authHeader(app),
    });
    expect(status.statusCode).toBe(200);
    expect(status.json()).toEqual({ paused: true });
    await app.close();
  });

  it("resume-internet fans resume_internet out to every device and clears the paused state", async () => {
    const app = await buildFullApp();
    store.set(PAUSED_KEY, JSON.stringify({ pausedAt: "2026-09-16T10:00:00.000Z" }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.device.findMany.mockResolvedValue(DEVICES);

    const res = await app.inject({
      method: "POST",
      url: "/v1/controls/children/child-1/resume-internet",
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ childId: "child-1", paused: false });

    const redis = getRedis() as unknown as MockRedis;
    for (const deviceId of ["dev-1", "dev-2"]) {
      expect(queuedCommands()).toContainEqual(expect.objectContaining({ deviceId, type: "resume_internet" }));
    }
    expect(store.has(PAUSED_KEY)).toBe(false);

    const status = await app.inject({
      method: "GET",
      url: "/v1/controls/children/child-1/status",
      headers: authHeader(app),
    });
    expect(status.statusCode).toBe(200);
    expect(status.json()).toEqual({ paused: false });
    await app.close();
  });

  it("bonus increments bonusMinutesToday, notifies devices, and is visible via GET /v1/rules", async () => {
    const app = await buildFullApp();
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.device.findMany.mockResolvedValue(DEVICES);
    // The upsert returns the post-increment row (15 = 0 + 15); a later grant would return 30.
    prismaMock.ruleSet.upsert.mockResolvedValue(flatRuleSet(15));
    prismaMock.ruleSet.findUnique.mockResolvedValue(flatRuleSet(15));

    const res = await app.inject({
      method: "POST",
      url: "/v1/controls/children/child-1/bonus",
      headers: authHeader(app),
      payload: { minutes: 15 },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().bonusMinutesToday).toBe(15);
    expect(res.json().alwaysAllowedApps).toEqual(["com.android.chrome"]);
    expect(prismaMock.ruleSet.upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { childId: "child-1" },
        update: { bonusMinutesToday: { increment: 15 } },
      }),
    );

    const redis = getRedis() as unknown as MockRedis;
    for (const deviceId of ["dev-1", "dev-2"]) {
      expect(queuedCommands()).toContainEqual(expect.objectContaining({ deviceId, type: "bonus_time", payload: { minutes: 15 } }));
    }
    expect(redis.publish).toHaveBeenCalledWith(
      "child:child-1:rules",
      expect.stringContaining('"bonusMinutesToday":15'),
    );

    const rules = await app.inject({
      method: "GET",
      url: "/v1/rules/child-1",
      headers: authHeader(app),
    });
    expect(rules.statusCode).toBe(200);
    expect(rules.json().bonusMinutesToday).toBe(15);
    await app.close();
  });

  it("rejects non-positive or non-integer bonus minutes with 400", async () => {
    const app = await buildFullApp();
    prismaMock.child.findUnique.mockResolvedValue(CHILD);

    for (const minutes of [0, -5, 1.5, "15"]) {
      const res = await app.inject({
        method: "POST",
        url: "/v1/controls/children/child-1/bonus",
        headers: authHeader(app),
        payload: { minutes },
      });
      expect(res.statusCode).toBe(400);
    }
    expect(prismaMock.ruleSet.upsert).not.toHaveBeenCalled();
    await app.close();
  });

  it("wind-down fans wind_down {minutes} out to every device (Feature #22)", async () => {
    const app = await buildFullApp();
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.device.findMany.mockResolvedValue(DEVICES);

    const res = await app.inject({
      method: "POST",
      url: "/v1/controls/children/child-1/wind-down",
      headers: authHeader(app),
      payload: { minutes: 30 },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ childId: "child-1", minutes: 30 });

    const redis = getRedis() as unknown as MockRedis;
    for (const deviceId of ["dev-1", "dev-2"]) {
      expect(redis.publish).toHaveBeenCalledWith(
        `device:${deviceId}:commands`,
        expect.stringContaining('"type":"wind_down"'),
      );
      expect(queuedCommands()).toContainEqual(expect.objectContaining({ deviceId, type: "wind_down", payload: { minutes: 30 } }));
    }
    await app.close();
  });

  it("rejects invalid wind-down minutes with 400", async () => {
    const app = await buildFullApp();
    prismaMock.child.findUnique.mockResolvedValue(CHILD);

    for (const minutes of [0, -10, 2.5, "30"]) {
      const res = await app.inject({
        method: "POST",
        url: "/v1/controls/children/child-1/wind-down",
        headers: authHeader(app),
        payload: { minutes },
      });
      expect(res.statusCode).toBe(400);
    }
    expect(prismaMock.device.findMany).not.toHaveBeenCalled();
    await app.close();
  });

  it("device command enum accepts the new world-class command types", async () => {
    const app = await buildFullApp();
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } });

    for (const command of ["pause_internet", "resume_internet", "bonus_time", "wind_down", "locate_now", "stop_ring"]) {
      const res = await app.inject({
        method: "POST",
        url: "/v1/devices/dev-1/command",
        headers: authHeader(app),
        payload: { command, payload: { minutes: 15 } },
      });
      expect(res.statusCode).toBe(200);
      expect(res.json().type).toBe(command);
    }
    await app.close();
  });

  it("enforces family isolation (403) on every child-scoped control route", async () => {
    const app = await buildFullApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-2" });

    const routes: Array<[string, string, unknown?]> = [
      ["POST", "/v1/controls/children/child-1/pause-internet"],
      ["POST", "/v1/controls/children/child-1/resume-internet"],
      ["POST", "/v1/controls/children/child-1/bonus", { minutes: 15 }],
      ["POST", "/v1/controls/children/child-1/wind-down", { minutes: 15 }],
      ["GET", "/v1/controls/children/child-1/status"],
    ];
    for (const [method, url, payload] of routes) {
      const res = await app.inject({ method: method as "POST" | "GET", url, headers: authHeader(app, "fam-1"), payload });
      expect(res.statusCode).toBe(403);
    }
    expect(prismaMock.device.findMany).not.toHaveBeenCalled();
    expect(prismaMock.ruleSet.upsert).not.toHaveBeenCalled();
    await app.close();
  });

  it("rejects unauthenticated calls with 401", async () => {
    const app = await buildFullApp();

    const unauth = await app.inject({
      method: "POST",
      url: "/v1/controls/children/child-1/pause-internet",
    });
    expect(unauth.statusCode).toBe(401);

    const status = await app.inject({ method: "GET", url: "/v1/controls/children/child-1/status" });
    expect(status.statusCode).toBe(401);

    const bonus = await app.inject({
      method: "POST",
      url: "/v1/controls/children/child-1/bonus",
      payload: { minutes: 15 },
    });
    expect(bonus.statusCode).toBe(401);
    expect(prismaMock.device.findMany).not.toHaveBeenCalled();
    await app.close();
  });
});
