import { isAbsolute } from "node:path";
import { Redis } from "ioredis";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { getRedis } from "../src/redis.js";
import { reserveStagingAiCall } from "../src/lib/stagingAiQuota.js";

vi.mock("../src/redis.js", () => ({ getRedis: vi.fn() }));

const familyDay = "2099-02-03";
const now = new Date("2099-02-02T22:30:00Z");
const unavailable = { allowed: false, reason: "unavailable" };
const mockedRedis = vi.mocked(getRedis);

describe("staging AI reservation configuration and failures", () => {
  const evaluate = vi.fn();
  beforeEach(() => {
    mockedRedis.mockReset();
    evaluate.mockReset();
    mockedRedis.mockReturnValue({ status: "ready", eval: evaluate } as unknown as Redis);
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("uses positive defaults, timezone-specific day keys and an opaque family key", async () => {
    evaluate.mockResolvedValue(["allowed", 1, 1, 0]);
    const familyId = "synthetic-family-identifier";
    expect(await reserveStagingAiCall(familyId, familyDay, now, {})).toEqual({
      allowed: true, familyCount: 1, globalCount: 1,
    });
    const [, keyCount, familyKey, globalKey, familyCap, globalCap, ttl] = evaluate.mock.calls[0];
    expect(keyCount).toBe(2);
    expect(familyKey).toContain(familyDay);
    expect(familyKey).not.toContain(familyId);
    expect(globalKey).toContain("2099-02-02");
    expect([familyCap, globalCap, ttl]).toEqual([250, 2000, 172800]);
  });

  it.each(["", "0", "-1", "4.5", "unset", "9007199254740992"])(
    "fails closed before Redis for a malformed cap %j",
    async (value) => {
      expect(await reserveStagingAiCall("family", familyDay, now, {
        OSRA_STAGING_AI_FAMILY_DAILY_CAP: value,
      })).toEqual(unavailable);
      expect(await reserveStagingAiCall("family", familyDay, now, {
        OSRA_STAGING_AI_GLOBAL_DAILY_CAP: value,
      })).toEqual(unavailable);
      expect(mockedRedis).not.toHaveBeenCalled();
    },
  );

  it("avoids queuing reservations when Redis is not ready", async () => {
    mockedRedis.mockReturnValue({ status: "reconnecting", eval: evaluate } as unknown as Redis);
    expect(await reserveStagingAiCall("family", familyDay, now, {})).toEqual(unavailable);
    expect(evaluate).not.toHaveBeenCalled();
  });

  it("falls back on Redis errors without logging any inputs", async () => {
    const log = vi.spyOn(console, "log");
    const warn = vi.spyOn(console, "warn");
    const error = vi.spyOn(console, "error");
    evaluate.mockRejectedValue(new Error("private test identifier"));
    expect(await reserveStagingAiCall("private test identifier", familyDay, now, {})).toEqual(unavailable);
    expect(log).not.toHaveBeenCalled();
    expect(warn).not.toHaveBeenCalled();
    expect(error).not.toHaveBeenCalled();
  });

  it("fails closed promptly when a ready Redis stops responding", async () => {
    vi.useFakeTimers();
    evaluate.mockImplementation(() => new Promise(() => undefined));
    const pending = reserveStagingAiCall("family", familyDay, now, {});
    await vi.advanceTimersByTimeAsync(500);
    expect(await pending).toEqual(unavailable);
  });
});

const redisTarget = process.env.OSRA_TEST_REDIS_URL;
if (process.env.OSRA_REQUIRE_REDIS_TESTS === "1" && !redisTarget) {
  throw new Error("OSRA_TEST_REDIS_URL is required for the staging AI quota Redis tests");
}
if (redisTarget && !isAbsolute(redisTarget)) {
  const { protocol, hostname } = new URL(redisTarget);
  if (protocol !== "redis:" || !(hostname === "localhost" || /^127(?:\.\d{1,3}){3}$/.test(hostname))) {
    throw new Error("The staging AI quota tests require a local Redis instance");
  }
}

const describeRedis = redisTarget ? describe : describe.skip;
describeRedis("staging AI quota atomicity against Redis", () => {
  const touchedKeys = new Set<string>();
  let client: Redis;

  beforeAll(async () => {
    client = new Redis(redisTarget!, { maxRetriesPerRequest: 1 });
    expect(await client.ping()).toBe("PONG");
  });

  beforeEach(() => {
    const evaluate = (script: string, keyCount: number, familyKey: string, globalKey: string,
      familyCap: number, globalCap: number, ttl: number) => {
      touchedKeys.add(familyKey);
      touchedKeys.add(globalKey);
      return client.eval(script, keyCount, familyKey, globalKey, familyCap, globalCap, ttl);
    };
    mockedRedis.mockReturnValue({ status: "ready", eval: evaluate } as unknown as Redis);
  });

  afterEach(async () => {
    if (touchedKeys.size) await client.del(...touchedKeys);
    touchedKeys.clear();
    mockedRedis.mockReset();
  });

  afterAll(async () => {
    await client?.quit();
  });

  it("allows only the family cap under concurrent reservations and preserves shared capacity", async () => {
    const env = { OSRA_STAGING_AI_FAMILY_DAILY_CAP: "3", OSRA_STAGING_AI_GLOBAL_DAILY_CAP: "10" };
    const results = await Promise.all(Array.from({ length: 20 }, () => reserveStagingAiCall("one", familyDay, now, env)));
    const admitted = results.filter((result) => result.allowed);
    const denied = results.filter((result) => !result.allowed);
    expect(admitted.map((result) => result.familyCount).sort()).toEqual([1, 2, 3]);
    expect(denied).toHaveLength(17);
    expect(denied.every((result) => result.reason === "family" && result.globalCount === 3)).toBe(true);
    expect(denied.filter((result) => result.log)).toHaveLength(1);
    expect(await reserveStagingAiCall("two", familyDay, now, env))
      .toEqual({ allowed: true, familyCount: 1, globalCount: 4 });
    const expiries = await Promise.all([...touchedKeys].map((key) => client.ttl(key)));
    expect(expiries.every((ttl) => ttl > 0 && ttl <= 48 * 60 * 60)).toBe(true);
  });

  it("enforces one shared global cap across concurrent families and reports one global warning", async () => {
    const env = { OSRA_STAGING_AI_FAMILY_DAILY_CAP: "10", OSRA_STAGING_AI_GLOBAL_DAILY_CAP: "4" };
    const results = await Promise.all(Array.from({ length: 24 }, (_, index) =>
      reserveStagingAiCall(`family-${index % 3}`, familyDay, now, env)));
    const admitted = results.filter((result) => result.allowed);
    const denied = results.filter((result) => !result.allowed);
    expect(admitted.map((result) => result.globalCount).sort()).toEqual([1, 2, 3, 4]);
    expect(denied).toHaveLength(20);
    expect(denied.every((result) => result.reason === "global" && result.globalCount === 4)).toBe(true);
    expect(denied.filter((result) => result.log)).toHaveLength(1);
  });

  it("resets each counter at its own day boundary", async () => {
    expect(await reserveStagingAiCall("family", "2099-02-02", now, {}))
      .toEqual({ allowed: true, familyCount: 1, globalCount: 1 });
    expect(await reserveStagingAiCall("family", familyDay, now, {}))
      .toEqual({ allowed: true, familyCount: 1, globalCount: 2 });
    expect(await reserveStagingAiCall("family", familyDay, new Date("2099-02-03T00:01:00Z"), {}))
      .toEqual({ allowed: true, familyCount: 2, globalCount: 1 });
  });
});
