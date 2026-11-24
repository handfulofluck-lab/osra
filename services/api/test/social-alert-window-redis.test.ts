import { randomUUID } from "node:crypto";
import { Redis } from "ioredis";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import {
  SOCIAL_ALERT_WINDOW_SECONDS,
  SOCIAL_PENDING_ACK_SCRIPT,
  SOCIAL_PENDING_DEFER_SCRIPT,
  SOCIAL_PENDING_PUBLISH_AND_PEEK_SCRIPT,
  replayDeferredSocialObservations,
  socialAlertDeferredKey,
  socialAlertThrottleKey,
  socialContactKey,
} from "../src/lib/socialAlertWindow.js";
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

  it("preserves both observations across two independent replicas against real Redis with a 150 ms insert and on deferred handoff", async () => {
    const childId = `child-${randomUUID()}`;
    const familyId = `fam-${randomUUID()}`;
    const appName = "WhatsApp";

    const alerts = new Map<string, Record<string, unknown>>();
    let seq = 0;
    const installAlertDbMock = (insertDelayMs: number) => {
      alerts.clear();
      seq = 0;
      let delayedOnce = false;
      prismaMock.alert.create.mockImplementation((async ({ data }: { data: Record<string, unknown> }) => {
        if (!delayedOnce && insertDelayMs > 0) {
          delayedOnce = true;
          await new Promise((resolve) => setTimeout(resolve, insertDelayMs));
        }
        seq += 1;
        const row = { id: `real-redis-alert-${seq}`, createdAt: new Date(), acknowledged: false, ...data };
        alerts.set(row.id, row);
        return row;
      }) as never);
      prismaMock.alert.findUnique.mockImplementation((async ({ where }: { where: { id: string } }) => alerts.get(where.id) ?? null) as never);
      prismaMock.alert.findMany.mockImplementation((async () => [...alerts.values()]) as never);
      prismaMock.alert.updateMany.mockImplementation((async ({ where, data }: { where: { id: string; attemptCount?: number }; data: Record<string, unknown> }) => {
        const cur = alerts.get(where.id);
        if (!cur) return { count: 0 };
        if (where.attemptCount !== undefined && cur.attemptCount !== where.attemptCount) return { count: 0 };
        alerts.set(where.id, { ...cur, ...data });
        return { count: 1 };
      }) as never);
      prismaMock.alert.update.mockImplementation((async ({ where, data }: { where: { id: string }; data: Record<string, unknown> }) => {
        const cur = alerts.get(where.id);
        if (!cur) return null;
        const next = { ...cur, ...data };
        alerts.set(where.id, next);
        return next;
      }) as never);
    };

    const replicaClients: Array<ReturnType<typeof getRedis>> = [];
    try {
      // Case A: Codex's exact 150 ms insert repro across two independently loaded replicas on real Redis.
      installAlertDbMock(150);
      const contactA = `Replica150-${randomUUID()}`;
      const keyA = trackKey(socialAlertThrottleKey(childId, appName, contactA));
      trackKey(`${keyA}:deferred`);

      vi.resetModules();
      const r1ARedis = await import("../src/redis.js");
      const replica1A = await import("../src/lib/socialAlertWindow.js");
      vi.resetModules();
      const r2ARedis = await import("../src/redis.js");
      const replica2A = await import("../src/lib/socialAlertWindow.js");
      expect(replica1A.recordFlaggedSocialAlert).not.toBe(replica2A.recordFlaggedSocialAlert);

      const p1A = replica1A.recordFlaggedSocialAlert({
        childId,
        familyId,
        childName: "Alex",
        appName,
        contact: contactA,
        category: "social_concern",
        severity: "warning",
        concernTypes: ["cyberbullying"],
      });
      await new Promise((resolve) => setTimeout(resolve, 15));
      const p2A = replica2A.recordFlaggedSocialAlert({
        childId,
        familyId,
        childName: "Alex",
        appName,
        contact: contactA,
        category: "social_concern",
        severity: "warning",
        concernTypes: ["cyberbullying"],
      });
      await Promise.all([p1A, p2A]);
      replicaClients.push(r1ARedis.getRedis(), r2ARedis.getRedis());

      expect(alerts.size).toBe(1);
      const rowA = [...alerts.values()][0]! as { attemptCount: number; metadata: { flaggedCount: number } };
      expect(rowA.attemptCount).toBe(2);
      expect(rowA.metadata.flaggedCount).toBe(2);

      // Case B: Insert slower than pendingWaitMs -> real Redis executes SOCIAL_PENDING_DEFER_SCRIPT +
      // SOCIAL_PENDING_PUBLISH_AND_PEEK_SCRIPT atomically and folds both observations with zero loss.
      installAlertDbMock(120);
      const contactB = `ReplicaDefer-${randomUUID()}`;
      const keyB = trackKey(socialAlertThrottleKey(childId, appName, contactB));
      // Claim-bound deferred key is tracked after alert creation below.

      vi.resetModules();
      const r1BRedis = await import("../src/redis.js");
      const replica1B = await import("../src/lib/socialAlertWindow.js");
      vi.resetModules();
      const r2BRedis = await import("../src/redis.js");
      const replica2B = await import("../src/lib/socialAlertWindow.js");

      const p1B = replica1B.recordFlaggedSocialAlert({
        childId,
        familyId,
        childName: "Alex",
        appName,
        contact: contactB,
        category: "social_concern",
        severity: "warning",
        concernTypes: ["cyberbullying"],
        pendingWaitMs: 25,
      });
      await new Promise((resolve) => setTimeout(resolve, 10));
      const p2B = replica2B.recordFlaggedSocialAlert({
        childId,
        familyId,
        childName: "Alex",
        appName,
        contact: contactB,
        category: "social_concern",
        severity: "critical",
        concernTypes: ["self_harm"],
        pendingWaitMs: 25,
      });
      await Promise.all([p1B, p2B]);
      replicaClients.push(r1BRedis.getRedis(), r2BRedis.getRedis());

      expect(alerts.size).toBe(1);
      const rowB = [...alerts.values()][0]! as { attemptCount: number; severity: string; metadata: { flaggedCount: number; windowClaimId: string } };
      const deferKeyB = trackKey(socialAlertDeferredKey(keyB, rowB.metadata.windowClaimId));
      expect(rowB.attemptCount).toBe(2);
      expect(rowB.metadata.flaggedCount).toBe(2);
      expect(rowB.severity).toBe("critical");
      expect(await client.llen(deferKeyB)).toBe(0);

      // Direct sanity on the two pending Lua scripts in real Redis: defer sees committed JSON if publish won first.
      const orderKey = trackKey(`${runPrefix}:publish-before-defer`);
      const orderDefer = trackKey(`${orderKey}:deferred`);
      const committedJson = JSON.stringify({
        alertId: "alert-committed",
        windowStartedAt: "2026-11-24T01:00:00.000Z",
        windowEndsAt: "2026-11-24T01:10:00.000Z",
        pushedSeverity: "warning",
      });
      const drained = await client.eval(
        SOCIAL_PENDING_PUBLISH_AND_PEEK_SCRIPT,
        2,
        orderKey,
        orderDefer,
        committedJson,
        String(SOCIAL_ALERT_WINDOW_SECONDS),
      );
      expect(drained).toEqual([]);
      const lateDefer = await client.eval(
        SOCIAL_PENDING_DEFER_SCRIPT,
        2,
        orderKey,
        orderDefer,
        "__pending__",
        "{}",
        String(SOCIAL_ALERT_WINDOW_SECONDS),
      );
      expect(lateDefer).toBe(committedJson);
      expect(await client.llen(orderDefer)).toBe(0);
    } finally {
      for (const rc of replicaClients) {
        await rc.quit().catch(() => undefined);
      }
    }
  });

  it("preserves deferred entries in real Redis across a pre-commit DB rejection and replays idempotently after post-commit ack loss", async () => {
    const childId = `child-${randomUUID()}`;
    const familyId = `fam-${randomUUID()}`;
    const appName = "WhatsApp";
    const contact = `CommitBoundaryReal-${randomUUID()}`;
    const throttleKey = trackKey(socialAlertThrottleKey(childId, appName, contact));
    // Claim-bound deferred key resolved from created alert metadata below.

    const alerts = new Map<string, Record<string, unknown>>();
    let delayedOnce = false;
    let failUpdateOnce = true;

    prismaMock.alert.create.mockImplementation((async ({ data }: { data: Record<string, unknown> }) => {
      if (!delayedOnce) {
        delayedOnce = true;
        await new Promise((resolve) => setTimeout(resolve, 120));
      }
      const row = { id: `real-boundary-${randomUUID()}`, createdAt: new Date(), acknowledged: false, ...data };
      alerts.set(row.id, row);
      return row;
    }) as never);
    prismaMock.alert.findUnique.mockImplementation((async ({ where }: { where: { id: string } }) => alerts.get(where.id) ?? null) as never);
    prismaMock.alert.findMany.mockImplementation((async () => [...alerts.values()]) as never);
    prismaMock.alert.updateMany.mockImplementation((async ({ where, data }: { where: { id: string; attemptCount?: number }; data: Record<string, unknown> }) => {
      if (failUpdateOnce) {
        failUpdateOnce = false;
        throw new Error("injected pre-commit DB error");
      }
      const cur = alerts.get(where.id);
      if (!cur) return { count: 0 };
      if (where.attemptCount !== undefined && cur.attemptCount !== where.attemptCount) return { count: 0 };
      alerts.set(where.id, { ...cur, ...data });
      return { count: 1 };
    }) as never);

    const replicaClients: Array<ReturnType<typeof getRedis>> = [];
    try {
      vi.resetModules();
      const r1Redis = await import("../src/redis.js");
      const replica1 = await import("../src/lib/socialAlertWindow.js");
      vi.resetModules();
      const r2Redis = await import("../src/redis.js");
      const replica2 = await import("../src/lib/socialAlertWindow.js");

      const p1 = replica1.recordFlaggedSocialAlert({
        childId,
        familyId,
        childName: "Alex",
        appName,
        contact,
        category: "social_concern",
        severity: "warning",
        concernTypes: ["cyberbullying"],
        pendingWaitMs: 25,
      });
      await new Promise((resolve) => setTimeout(resolve, 10));
      const p2 = replica2.recordFlaggedSocialAlert({
        childId,
        familyId,
        childName: "Alex",
        appName,
        contact,
        category: "social_concern",
        severity: "warning",
        concernTypes: ["cyberbullying"],
        pendingWaitMs: 25,
      });

      await expect(p2).resolves.toMatchObject({ throttled: true });
      await expect(p1).rejects.toThrow("injected pre-commit DB error");
      replicaClients.push(r1Redis.getRedis(), r2Redis.getRedis());

      // Side 1 (before commit): DB at 1, real Redis still holds the deferred entry.
      const row = [...alerts.values()][0]! as { id: string; attemptCount: number; metadata: { flaggedCount: number; windowClaimId: string } };
      const deferKey = trackKey(socialAlertDeferredKey(throttleKey, row.metadata.windowClaimId));
      expect(row.attemptCount).toBe(1);
      const pendingRaw = await client.lrange(deferKey, 0, -1);
      expect(pendingRaw).toHaveLength(1);

      // Recovery replay commits count = 2 and trims real Redis.
      await replayDeferredSocialObservations(row as never, { familyId, childName: "Alex" });
      const afterRecover = alerts.get(row.id)! as { attemptCount: number; metadata: { flaggedCount: number } };
      expect(afterRecover.attemptCount).toBe(2);
      expect(afterRecover.metadata.flaggedCount).toBe(2);
      expect(await client.llen(deferKey)).toBe(0);

      // Side 2 (after commit, before Redis ack): re-push exact same entry -> replay is idempotent (stays 2).
      await client.rpush(deferKey, pendingRaw[0]!);
      await replayDeferredSocialObservations(afterRecover as never, { familyId, childName: "Alex" });
      const afterReplay = alerts.get(row.id)! as { attemptCount: number; metadata: { flaggedCount: number } };
      expect(afterReplay.attemptCount).toBe(2);
      expect(afterReplay.metadata.flaggedCount).toBe(2);
      expect(await client.llen(deferKey)).toBe(0);

      // SOCIAL_PENDING_ACK_SCRIPT trims only the acknowledged prefix, keeping newer concurrent items.
      const ackKey = trackKey(`${runPrefix}:ack-prefix`);
      await client.rpush(ackKey, "first", "second");
      expect(await client.eval(SOCIAL_PENDING_ACK_SCRIPT, 1, ackKey, "1")).toBe(1);
      expect(await client.lrange(ackKey, 0, -1)).toEqual(["second"]);
    } finally {
      for (const rc of replicaClients) {
        await rc.quit().catch(() => undefined);
      }
    }
  });

  it("preserves deferred entries in real Redis on 6-conflict CAS exhaustion and binds sweep replay to the originating window in both candidate orders", async () => {
    const childId = `child-${randomUUID()}`;
    const familyId = `fam-${randomUUID()}`;
    const appName = "WhatsApp";

    // Part A: 6-conflict CAS exhaustion against real Redis -> retryable=true, DB=1, Redis LLEN=1 -> replay commits 2, LLEN=0.
    const contact6 = `SixConflictsReal-${randomUUID()}`;
    const throttle6 = trackKey(socialAlertThrottleKey(childId, appName, contact6));
    const alerts6 = new Map<string, Record<string, unknown>>();
    let delayedOnce = false;
    let remainingConflicts = 6;
    prismaMock.alert.create.mockImplementation((async ({ data }: { data: Record<string, unknown> }) => {
      if (!delayedOnce) {
        delayedOnce = true;
        await new Promise((resolve) => setTimeout(resolve, 120));
      }
      const row = { id: `real-6c-${randomUUID()}`, createdAt: new Date(), acknowledged: false, ...data };
      alerts6.set(row.id, row);
      return row;
    }) as never);
    prismaMock.alert.findUnique.mockImplementation((async ({ where }: { where: { id: string } }) => alerts6.get(where.id) ?? null) as never);
    prismaMock.alert.updateMany.mockImplementation((async ({ where, data }: { where: { id: string; attemptCount?: number }; data: Record<string, unknown> }) => {
      if (remainingConflicts > 0) {
        remainingConflicts -= 1;
        return { count: 0 };
      }
      const cur = alerts6.get(where.id);
      if (!cur || (where.attemptCount !== undefined && cur.attemptCount !== where.attemptCount)) return { count: 0 };
      alerts6.set(where.id, { ...cur, ...data });
      return { count: 1 };
    }) as never);

    const replicaClients: Array<ReturnType<typeof getRedis>> = [];
    try {
      vi.resetModules();
      const r1Redis = await import("../src/redis.js");
      const replica1 = await import("../src/lib/socialAlertWindow.js");
      vi.resetModules();
      const r2Redis = await import("../src/redis.js");
      const replica2 = await import("../src/lib/socialAlertWindow.js");

      const p1 = replica1.recordFlaggedSocialAlert({
        childId,
        familyId,
        childName: "Alex",
        appName,
        contact: contact6,
        category: "social_concern",
        severity: "warning",
        concernTypes: ["cyberbullying"],
        pendingWaitMs: 25,
      });
      await new Promise((resolve) => setTimeout(resolve, 10));
      const p2 = replica2.recordFlaggedSocialAlert({
        childId,
        familyId,
        childName: "Alex",
        appName,
        contact: contact6,
        category: "social_concern",
        severity: "warning",
        concernTypes: ["cyberbullying"],
        pendingWaitMs: 25,
      });
      const [res1, res2] = await Promise.all([p1, p2]);
      replicaClients.push(r1Redis.getRedis(), r2Redis.getRedis());

      expect(res2.throttled).toBe(true);
      expect(res1.retryable).toBe(true);
      const row6 = [...alerts6.values()][0]! as { id: string; attemptCount: number; metadata: { flaggedCount: number; windowClaimId: string } };
      const deferKey6 = trackKey(socialAlertDeferredKey(throttle6, row6.metadata.windowClaimId));
      expect(row6.attemptCount).toBe(1);
      expect(await client.llen(deferKey6)).toBe(1);

      await replayDeferredSocialObservations(row6 as never, { familyId, childName: "Alex" });
      const recovered6 = alerts6.get(row6.id)! as { attemptCount: number; metadata: { flaggedCount: number } };
      expect(recovered6.attemptCount).toBe(2);
      expect(recovered6.metadata.flaggedCount).toBe(2);
      expect(await client.llen(deferKey6)).toBe(0);

      // Part B: Window-bound sweep replay in BOTH candidate orders ([old, current] and [current, old]) against real Redis.
      const contactW = `WindowBoundReal-${randomUUID()}`;
      const throttleW = trackKey(socialAlertThrottleKey(childId, appName, contactW));
      const contactKeyW = socialContactKey(childId, contactW);

      for (const order of ["old-first", "current-first"] as const) {
        const alertsW = new Map<string, Record<string, unknown>>();
        const oldClaim = `rc-old-${randomUUID()}`;
        const curClaim = `rc-cur-${randomUUID()}`;
        const curDeferKey = trackKey(socialAlertDeferredKey(throttleW, curClaim));
        const oldRow = {
          id: `real-old-${order}`,
          childId,
          deviceId: null,
          severity: "warning",
          category: "social_concern",
          title: "Social concern",
          body: "1",
          attemptCount: 1,
          acknowledged: false,
          createdAt: new Date("2026-11-24T00:40:00.000Z"),
          metadata: {
            app: appName,
            contact: contactW,
            contactKey: contactKeyW,
            windowClaimId: oldClaim,
            flaggedCount: 1,
            pushedCount: 1,
            pushedSeverity: "warning",
            windowStartedAt: "2026-11-24T00:40:00.000Z",
            windowEndsAt: "2026-11-24T00:50:00.000Z",
            latestAt: "2026-11-24T00:40:00.000Z",
            summaryPending: false,
            summaryPushed: false,
          },
          child: { familyId, displayName: "Alex" },
        };
        const curRow = {
          id: `real-cur-${order}`,
          childId,
          deviceId: null,
          severity: "warning",
          category: "social_concern",
          title: "Social concern",
          body: "1",
          attemptCount: 1,
          acknowledged: false,
          createdAt: new Date("2026-11-24T01:00:00.000Z"),
          metadata: {
            app: appName,
            contact: contactW,
            contactKey: contactKeyW,
            windowClaimId: curClaim,
            flaggedCount: 1,
            pushedCount: 1,
            pushedSeverity: "warning",
            windowStartedAt: "2026-11-24T01:00:00.000Z",
            windowEndsAt: "2026-11-24T01:10:00.000Z",
            latestAt: "2026-11-24T01:00:00.000Z",
            summaryPending: false,
            summaryPushed: false,
          },
          child: { familyId, displayName: "Alex" },
        };
        alertsW.set(oldRow.id, oldRow);
        alertsW.set(curRow.id, curRow);
        prismaMock.alert.findUnique.mockImplementation((async ({ where }: { where: { id: string } }) => alertsW.get(where.id) ?? null) as never);
        prismaMock.alert.updateMany.mockImplementation((async ({ where, data }: { where: { id: string; attemptCount?: number }; data: Record<string, unknown> }) => {
          const cur = alertsW.get(where.id);
          if (!cur || (where.attemptCount !== undefined && cur.attemptCount !== where.attemptCount)) return { count: 0 };
          alertsW.set(where.id, { ...cur, ...data });
          return { count: 1 };
        }) as never);
        prismaMock.alert.findMany.mockResolvedValueOnce(order === "old-first" ? [oldRow, curRow] : [curRow, oldRow]);

        await client.rpush(
          curDeferKey,
          JSON.stringify({
            id: `real-obs-${order}`,
            claimId: curClaim,
            severity: "warning",
            concernTypes: ["cyberbullying"],
            observedAt: "2026-11-24T01:00:05.000Z",
          }),
        );

        await runSocialAlertSummarySweep(new Date("2026-11-24T01:01:00.000Z"));
        expect((alertsW.get(oldRow.id) as { attemptCount: number }).attemptCount).toBe(1);
        expect((alertsW.get(curRow.id) as { attemptCount: number }).attemptCount).toBe(2);
        expect(await client.llen(curDeferKey)).toBe(0);
      }
    } finally {
      for (const rc of replicaClients) {
        await rc.quit().catch(() => undefined);
      }
    }
  });
});
