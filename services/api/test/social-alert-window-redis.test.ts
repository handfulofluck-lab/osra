import { randomUUID } from "node:crypto";
import { Redis } from "ioredis";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { SOCIAL_ALERT_WINDOW_SECONDS, socialContactKey } from "../src/lib/socialAlertWindow.js";
import { SOCIAL_WINDOW_ROLLOVER_SCRIPT, runSocialAlertSummarySweep } from "../src/jobs/socialAlertSummary.js";
import { getRedis } from "../src/redis.js";
import { prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("../src/realtime/gateway.js", () => ({
  publishFamilyEvent: vi.fn(async () => undefined),
}));
vi.mock("../src/lib/push/notify.js", () => ({
  notifyParentsOfAlert: vi.fn(async () => ({ recipients: 1, delivered: 1, pruned: 0, skipped: null })),
}));

const redisUrl = process.env.OSRA_TEST_REDIS_URL;

if (process.env.OSRA_REQUIRE_REDIS_TESTS === "1" && !redisUrl) {
  throw new Error("OSRA_TEST_REDIS_URL is required when OSRA_REQUIRE_REDIS_TESTS=1");
}

if (redisUrl) {
  const parsed = new URL(redisUrl);
  if (!["127.0.0.1", "localhost", "::1"].includes(parsed.hostname)) {
    throw new Error("The Redis Lua tests require a loopback Redis instance (127.0.0.1 / localhost / ::1)");
  }
}

const describeRedis = redisUrl ? describe.sequential : describe.skip;

/**
 * Real-Redis Lua execution tests for `SOCIAL_WINDOW_ROLLOVER_SCRIPT` (issue #1029, Codex review of #1033).
 *
 * Unlike `test/social-alert-window.test.ts` (which mocks ioredis for fast unit runs), this suite connects
 * directly to a real Redis instance (`OSRA_TEST_REDIS_URL`, enforced in CI via `OSRA_REQUIRE_REDIS_TESTS=1`)
 * and runs the exact exported Lua script through `EVAL` — with zero JS reimplementation.
 *
 * Mutant killed: changing the `if (not cur) or string.find(cur, ARGV[1], 1, true) then` guard in
 * `SOCIAL_WINDOW_ROLLOVER_SCRIPT` (`services/api/src/jobs/socialAlertSummary.ts`) to write unconditionally
 * breaks both the direct Lua newer-window / `__pending__` tests and the end-to-end sweep test below.
 */
describeRedis("social alert window Lua rollover against real Redis (#1029)", () => {
  const runPrefix = `osra:test:social-rollover:${randomUUID()}`;
  const touchedKeys = new Set<string>();
  const savedRedisUrl = process.env.REDIS_URL;
  let client: Redis;

  const trackKey = (key: string): string => {
    touchedKeys.add(key);
    return key;
  };

  beforeAll(async () => {
    process.env.REDIS_URL = redisUrl!;
    client = new Redis(redisUrl!, { maxRetriesPerRequest: 2 });
    expect(await client.ping()).toBe("PONG");
  });

  beforeEach(() => {
    resetPrismaMock();
    process.env.VAULT_KEY = Buffer.alloc(32, 9).toString("base64");
  });

  afterEach(async () => {
    if (touchedKeys.size > 0) {
      await client.del(...touchedKeys);
      touchedKeys.clear();
    }
  });

  afterAll(async () => {
    await getRedis().quit().catch(() => undefined);
    await client.quit().catch(() => undefined);
    if (savedRedisUrl === undefined) delete process.env.REDIS_URL;
    else process.env.REDIS_URL = savedRedisUrl;
  });

  it("renews an absent or matching window in real Redis and preserves a newer window or __pending__ claim", async () => {
    const expectedOldToken = `"alertId":${JSON.stringify("alert-old")}`;
    const rolloverPayload = JSON.stringify({
      alertId: "alert-old",
      windowStartedAt: "2026-11-24T01:10:00.000Z",
      windowEndsAt: "2026-11-24T01:20:00.000Z",
      pushedSeverity: "warning",
    });

    // 1. Absent (expired) key -> writes rollover state with TTL and returns 1.
    const absentKey = trackKey(`${runPrefix}:absent`);
    const absentRes = await client.eval(
      SOCIAL_WINDOW_ROLLOVER_SCRIPT,
      1,
      absentKey,
      expectedOldToken,
      rolloverPayload,
      String(SOCIAL_ALERT_WINDOW_SECONDS),
    );
    expect(absentRes).toBe(1);
    expect(await client.get(absentKey)).toBe(rolloverPayload);
    const absentTtl = await client.ttl(absentKey);
    expect(absentTtl).toBeGreaterThan(0);
    expect(absentTtl).toBeLessThanOrEqual(SOCIAL_ALERT_WINDOW_SECONDS);

    // 2. Matching alertId -> updates window state and returns 1.
    const matchKey = trackKey(`${runPrefix}:match`);
    await client.set(
      matchKey,
      JSON.stringify({ alertId: "alert-old", windowStartedAt: "2026-11-24T01:00:00.000Z", windowEndsAt: "2026-11-24T01:10:00.000Z", pushedSeverity: "warning" }),
      "EX",
      60,
    );
    const matchRes = await client.eval(
      SOCIAL_WINDOW_ROLLOVER_SCRIPT,
      1,
      matchKey,
      expectedOldToken,
      rolloverPayload,
      String(SOCIAL_ALERT_WINDOW_SECONDS),
    );
    expect(matchRes).toBe(1);
    expect(await client.get(matchKey)).toBe(rolloverPayload);

    // 3. Control: newer alertId -> returns 0 and leaves the newer window untouched.
    const newerKey = trackKey(`${runPrefix}:newer`);
    const newerPayload = JSON.stringify({
      alertId: "alert-newer",
      windowStartedAt: "2026-11-24T01:10:05.000Z",
      windowEndsAt: "2026-11-24T01:20:05.000Z",
      pushedSeverity: "warning",
    });
    await client.set(newerKey, newerPayload, "EX", SOCIAL_ALERT_WINDOW_SECONDS);
    const newerRes = await client.eval(
      SOCIAL_WINDOW_ROLLOVER_SCRIPT,
      1,
      newerKey,
      expectedOldToken,
      rolloverPayload,
      String(SOCIAL_ALERT_WINDOW_SECONDS),
    );
    expect(newerRes).toBe(0);
    expect(await client.get(newerKey)).toBe(newerPayload);

    // 4. Control: in-flight __pending__ claim -> returns 0 and preserves __pending__.
    const pendingKey = trackKey(`${runPrefix}:pending`);
    await client.set(pendingKey, "__pending__", "EX", 30);
    const pendingRes = await client.eval(
      SOCIAL_WINDOW_ROLLOVER_SCRIPT,
      1,
      pendingKey,
      expectedOldToken,
      rolloverPayload,
      String(SOCIAL_ALERT_WINDOW_SECONDS),
    );
    expect(pendingRes).toBe(0);
    expect(await client.get(pendingKey)).toBe("__pending__");

    // 5. Positive control for the unconditional-write mutant: replacing the Lua guard with `if true then`
    // DOES overwrite the newer window in real Redis, proving tests 3 & 4 fail if the shipped guard is removed.
    const mutantScript = SOCIAL_WINDOW_ROLLOVER_SCRIPT.replace(
      /if\s+\(not cur\)\s+or\s+string\.find\(cur,\s*ARGV\[1\],\s*1,\s*true\)\s+then/,
      "if true then",
    );
    expect(mutantScript).not.toBe(SOCIAL_WINDOW_ROLLOVER_SCRIPT);
    const mutantKey = trackKey(`${runPrefix}:mutant-control`);
    await client.set(mutantKey, newerPayload, "EX", SOCIAL_ALERT_WINDOW_SECONDS);
    const mutantRes = await client.eval(
      mutantScript,
      1,
      mutantKey,
      expectedOldToken,
      rolloverPayload,
      String(SOCIAL_ALERT_WINDOW_SECONDS),
    );
    expect(mutantRes).toBe(1);
    expect(await client.get(mutantKey)).toBe(rolloverPayload);
  });

  it("runSocialAlertSummarySweep executes the real Lua script against real Redis and preserves a newer active window", async () => {
    const childId = `child-${randomUUID()}`;
    const appName = "WhatsApp";
    const contactKey = socialContactKey(childId, appName, "DelayedSweepRealRedis");
    const throttleKey = trackKey(`social:alert:${childId}:${appName.toLowerCase()}:${contactKey}`);
    const oldAlertId = `alert-old-${randomUUID()}`;
    const newAlertId = `alert-new-${randomUUID()}`;
    const windowEndsAt = "2026-11-24T01:10:00.000Z";
    trackKey(`jobs:social-summary:${oldAlertId}:${windowEndsAt}`);

    const newerState = JSON.stringify({
      alertId: newAlertId,
      windowStartedAt: "2026-11-24T01:10:05.000Z",
      windowEndsAt: "2026-11-24T01:20:05.000Z",
      pushedSeverity: "warning",
    });
    await client.set(throttleKey, newerState, "EX", SOCIAL_ALERT_WINDOW_SECONDS);

    const oldRow = {
      id: oldAlertId,
      childId,
      deviceId: null,
      severity: "warning",
      category: "social_concern",
      title: "Social concern",
      body: "Flagged",
      attemptCount: 2,
      acknowledged: false,
      createdAt: new Date("2026-11-24T01:00:00.000Z"),
      metadata: {
        app: appName,
        contact: "DelayedSweepRealRedis",
        contactKey,
        flaggedCount: 2,
        pushedCount: 1,
        pushedSeverity: "warning",
        windowStartedAt: "2026-11-24T01:00:00.000Z",
        windowEndsAt,
        latestAt: "2026-11-24T01:01:00.000Z",
        summaryPending: true,
        summaryPushed: false,
      },
      child: { familyId: "fam-real-redis", displayName: "Alex" },
    };

    prismaMock.alert.findMany.mockResolvedValue([oldRow]);
    prismaMock.alert.update.mockImplementation((async ({ data }: { data: Record<string, unknown> }) => ({
      ...oldRow,
      ...data,
    })) as never);

    const sweep = await runSocialAlertSummarySweep(new Date("2026-11-24T01:10:30.000Z"));
    expect(sweep.pushed.map((p) => p.alertId)).toEqual([oldAlertId]);
    // Real Redis evaluated SOCIAL_WINDOW_ROLLOVER_SCRIPT and kept the newer window intact.
    expect(await client.get(throttleKey)).toBe(newerState);
  });
});