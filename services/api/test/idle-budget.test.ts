import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  BUDGET_WINDOW_MINUTES,
  countingEnabled,
  idleBudgetThreshold,
  minuteOf,
  registerIdleBudgetHook,
  routeKey,
  summarise,
  withinBudget,
} from "../src/lib/idleBudget.js";
import { deviceRoutes } from "../src/routes/devices.js";
import { MockRedis, authHeader, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";
import { getRedis } from "../src/redis.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});
vi.mock("../src/lib/push/notify.js", () => ({ notifyParentsOfAlert: vi.fn(async () => undefined) }));
vi.mock("../src/realtime/gateway.js", () => ({ publishFamilyEvent: vi.fn(async () => undefined) }));

/** The harness turns counting on (`vitest.config.ts`); a case that needs it off deletes it for its own body. */
afterEach(() => {
  process.env.IDLE_BUDGET_COUNTING = "1";
  delete process.env.IDLE_BUDGET_M10;
});

beforeEach(() => {
  // `getRedis()` is one mock instance for the whole file, so every case starts from an empty hash.
  const redis = getRedis() as unknown as MockRedis;
  redis.hashes.clear();
  redis.multi.mockClear();
  redis.hincrby.mockClear();
  redis.expire.mockClear();
});

/**
 * Roadmap 5.8's second half: "idle child phone ≤ 3 requests per 10 min with lock still ≤ 5 s". These are the
 * arithmetic and the key shape; the count itself is Redis's.
 */
describe("the idle-request budget", () => {
  it("coarsens a route key so a count cannot name a child or a command", () => {
    expect(routeKey("GET", "/v1/devices/9f1c8b6e-1111-4222-8333-444455556666/commands?ack=1")).toBe("GET /v1/devices/:id/commands");
    expect(routeKey("post", "/v1/devices/9f1c8b6e-1111-4222-8333-444455556666/telemetry")).toBe("POST /v1/devices/:id/telemetry");
    expect(routeKey("GET", "/v1/location/ping")).toBe("GET /v1/location/ping");
    // a numeric segment and a hex id are coarsened too, so a route cannot leak an identifier
    expect(routeKey("GET", "/v1/reports/usage/2026/12345")).toBe("GET /v1/reports/usage/:n/:n");
  });

  it("counts one window and finds the busiest one, not the average", () => {
    const now = new Date("2026-10-24T10:00:00Z");
    const m = minuteOf(now);
    // One request per minute for the last 5 minutes: 5 in the current window.
    const steady: Record<string, Record<string, number>> = {};
    for (let i = 0; i < 5; i += 1) steady[String(m - i)] = { "GET /v1/devices/:id/commands": 1 };

    const flat = summarise(steady, { now });
    expect(flat.total).toBe(5);
    expect(flat.busiest?.count).toBe(5);

    // A burst: 4 requests in one minute, then nothing. The average is under budget; the window is not.
    const bursty: Record<string, Record<string, number>> = { [String(m - 30)]: { "GET /v1/devices/:id/commands": 4 } };
    const burst = summarise(bursty, { now });
    expect(burst.total).toBe(0); // outside the current window
    expect(burst.busiest).toEqual({ startMinute: m - 30, count: 4, byRoute: { "GET /v1/devices/:id/commands": 4 } });
  });

  it("rolls a burst into the window that contains it", () => {
    const now = new Date("2026-10-24T10:00:00Z");
    const m = minuteOf(now);
    const counts = { [String(m - 9)]: { "GET /v1/devices/:id/commands": 2 }, [String(m - 1)]: { "GET /v1/devices/:id/commands": 2 } };
    const result = summarise(counts, { now });
    expect(result.total).toBe(4);
    expect(result.busiest?.count).toBe(4);
  });

  it("is not a gate until a threshold is measured", () => {
    expect(idleBudgetThreshold({})).toBeNull();
    expect(idleBudgetThreshold({ IDLE_BUDGET_M10: "" })).toBeNull();
    expect(idleBudgetThreshold({ IDLE_BUDGET_M10: "nonsense" })).toBeNull();
    expect(idleBudgetThreshold({ IDLE_BUDGET_M10: "3" })).toBe(3);

    const now = new Date("2026-10-24T10:00:00Z");
    const counts = { [String(minuteOf(now))]: { "GET /v1/devices/:id/commands": 4 } };
    const result = summarise(counts, { now });
    expect(withinBudget(result, null)).toBeNull(); // reports, does not fail
    expect(withinBudget(result, 3)).toBe(false);
    expect(withinBudget(result, 4)).toBe(true);
  });

  it("an idle device is zero, not absent", () => {
    const result = summarise({}, { now: new Date("2026-10-24T10:00:00Z") });
    expect(result).toMatchObject({ windowMinutes: BUDGET_WINDOW_MINUTES, total: 0, byRoute: {}, busiest: null, minutesWithTraffic: 0 });
    expect(withinBudget(result, 3)).toBe(true);
  });

  it("ignores a count outside the requested window rather than counting it", () => {
    const now = new Date("2026-10-24T10:00:00Z");
    const m = minuteOf(now);
    const counts = { [String(m - 60)]: { "GET /v1/devices/:id/commands": 9 } };
    expect(summarise(counts, { now }).total).toBe(0);
    expect(summarise(counts, { now: now, windowMinutes: 90 }).total).toBe(9);
  });

  it("is off unless the environment says exactly 1", () => {
    // Mutant: return true when the variable is merely present (`!== undefined`) — then every production
    // request writes telemetry again, which is the architecture call this flag exists to make.
    expect(countingEnabled({})).toBe(false);
    expect(countingEnabled({ IDLE_BUDGET_COUNTING: "" })).toBe(false);
    expect(countingEnabled({ IDLE_BUDGET_COUNTING: "0" })).toBe(false);
    expect(countingEnabled({ IDLE_BUDGET_COUNTING: "true" })).toBe(false);
    expect(countingEnabled({ IDLE_BUDGET_COUNTING: "1" })).toBe(true);
  });
});

describe("the requests route", () => {
  beforeEach(() => {
    resetPrismaMock();
    delete process.env.IDLE_BUDGET_M10;
  });

  it("answers a parent with the measured rate, and never labels it a pass without a threshold", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } });
    // Seed the instance production reads, not a fresh one: getRedis() is a singleton created from the mock.
    const redis = getRedis() as unknown as MockRedis;
    const now = new Date();
    const minute = Math.floor(now.getTime() / 60_000);
    redis.seedHash("idle:dev:dev-1", {
      [`${minute}:GET /v1/devices/:id/commands`]: "2",
      [`${minute}:POST /v1/devices/:id/telemetry`]: "1",
    });

    const res = await app.inject({ method: "GET", url: "/v1/devices/dev-1/requests", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    const body = res.json() as { counting: boolean; total: number; byRoute: Record<string, number>; threshold: number | null; withinBudget: boolean | null };
    // The harness has IDLE_BUDGET_COUNTING=1 (vitest.config.ts), so this reading is one being recorded.
    expect(body.counting).toBe(true);
    expect(body.total).toBe(3);
    expect(body.byRoute["GET /v1/devices/:id/commands"]).toBe(2);
    // No threshold measured yet: the route reports the number and refuses to pronounce on it.
    expect(body.threshold).toBeNull();
    expect(body.withinBudget).toBeNull();
    await app.close();
  });

  it("says counting is off rather than reporting an unmeasured device as idle", async () => {
    // Mutant: compute `withinBudget(result, threshold)` without consulting the flag. An empty reading then
    // answers `withinBudget: true` for a threshold of 3 — "nobody was counting" printed as "the phone is idle".
    delete process.env.IDLE_BUDGET_COUNTING;
    process.env.IDLE_BUDGET_M10 = "3";
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } });

    const res = await app.inject({ method: "GET", url: "/v1/devices/dev-1/requests", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    const body = res.json() as { counting: boolean; total: number; busiestWindow: unknown; withinBudget: boolean | null };
    expect(body.counting).toBe(false);
    expect(body.total).toBe(0);
    expect(body.busiestWindow).toBeNull();
    expect(body.withinBudget).toBeNull(); // not `true`
    await app.close();
  });

  it("refuses a device token (403) — the agent does not read its own accounting", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } });
    const res = await app.inject({ method: "GET", url: "/v1/devices/dev-1/requests", headers: deviceHeader(app) });
    expect(res.statusCode).toBe(403);
    await app.close();
  });
});

/**
 * Counting is a test instrument, not production telemetry (Claude, #346 review). It runs only with
 * `IDLE_BUDGET_COUNTING=1`, so the gate that turns it on is asserted here rather than trusted: an
 * instrument that silently writes in production is a Redis bill and a collision with durable revocation.
 */
describe("counting runs only when it is switched on", () => {
  /** An app whose only route needs a valid device JWT, so the hook sees exactly what production hands it. */
  async function deviceApp() {
    return buildApp(async (a) => {
      registerIdleBudgetHook(a);
      a.addHook("preHandler", async (req) => {
        await req.jwtVerify();
      });
      a.get("/ping", async () => ({ ok: true }));
    }, "/t");
  }

  it("records nothing for an authenticated device request when the variable is unset", async () => {
    // Mutant: drop the `countingEnabled()` guard in `recordDeviceRequest`. The device request below still
    // answers 200, and the hash is no longer empty — every production request writes telemetry again.
    delete process.env.IDLE_BUDGET_COUNTING;
    const app = await deviceApp();
    const redis = getRedis() as unknown as MockRedis;

    const res = await app.inject({ method: "GET", url: "/t/ping", headers: deviceHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(redis.hashes.get("idle:dev:dev-1")).toBeUndefined();
    expect(redis.multi).not.toHaveBeenCalled();
    await app.close();
  });

  it("records one count and its hour, in a single MULTI, when the variable is 1", async () => {
    process.env.IDLE_BUDGET_COUNTING = "1";
    const app = await deviceApp();
    const redis = getRedis() as unknown as MockRedis;

    const res = await app.inject({ method: "GET", url: "/t/ping", headers: deviceHeader(app) });
    expect(res.statusCode).toBe(200);
    const hash = redis.hashes.get("idle:dev:dev-1") ?? {};
    expect(Object.keys(hash)).toEqual([`${minuteOf(Date.now())}:GET /t/ping`]);
    expect(Object.values(hash)).toEqual(["1"]);
    // Mutant: `await hincrby(...)` then `await expire(...)` — two round trips, and `multi` is never called.
    expect(redis.multi).toHaveBeenCalledTimes(1);
    // 3600 literal, not RETENTION_MINUTES * 60: a retention that drifts back to three hours must fail here.
    expect(redis.expire).toHaveBeenCalledWith("idle:dev:dev-1", 3600);
    await app.close();
  });

  it("counts no parent request, so a parent opening the read route cannot inflate it", async () => {
    process.env.IDLE_BUDGET_COUNTING = "1";
    const app = await deviceApp();
    const redis = getRedis() as unknown as MockRedis;

    const res = await app.inject({ method: "GET", url: "/t/ping", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(redis.hashes.size).toBe(0);
    await app.close();
  });
});
