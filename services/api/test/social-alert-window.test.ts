import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { signV2 } from "../src/lib/internalAuth.js";
import { socialRoutes } from "../src/routes/social.js";
import {
  SOCIAL_ALERT_WINDOW_MS,
  SOCIAL_PENDING_ACK_SCRIPT,
  SOCIAL_PENDING_DEFER_SCRIPT,
  SOCIAL_PENDING_PUBLISH_AND_PEEK_SCRIPT,
  SOCIAL_PENDING_RELEASE_SCRIPT,
  replayDeferredSocialObservations,
  socialAlertDeferredKey,
  socialAlertThrottleKey,
  socialAlertFirstPushes,
  socialAlertSummaryMinutes,
  socialAlertWindowMs,
  socialContactKey,
} from "../src/lib/socialAlertWindow.js";
import { SOCIAL_WINDOW_ROLLOVER_SCRIPT, runSocialAlertSummarySweep } from "../src/jobs/socialAlertSummary.js";
import { setPushProviders } from "../src/lib/push/notify.js";
import type { PushMessage, PushProvider } from "../src/lib/push/types.js";
import { getRedis } from "../src/redis.js";
import { MockRedis, buildApp, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const SECRET = "test-internal-secret";
const VAULT_KEY = Buffer.alloc(32, 9).toString("base64");
const CHILD = {
  id: "child-1",
  familyId: "fam-1",
  displayName: "Alex",
  birthYear: 2012,
  family: { timezone: "Asia/Dubai" },
};

interface StoredAlert {
  id: string;
  childId: string;
  deviceId: string | null;
  severity: string;
  category: string;
  title: string;
  body: string;
  metadata: Record<string, unknown>;
  attemptCount: number;
  acknowledged: boolean;
  createdAt: Date;
}

/**
 * End-to-end tests for issue #1029 (per-contact 10-minute social alert window, in-place
 * running count + latestAt, window-close summary push, severity bypass, and lock-screen privacy).
 *
 * Mutants killed by this suite:
 * - Keying throttle by `(childId, app)` without `contactKey`: breaks test 1 (11 msgs from 3 contacts
 *   would produce 1 push instead of 3).
 * - Putting raw contact name in Redis key or push payload: breaks test 5.
 * - Dropping in-place alert update or `flaggedCount`/`latestAt`: breaks tests 1, 2, 7.
 * - Dropping severity bypass check (`>` vs `>=` or removing bypass): breaks test 3.
 * - Sending a summary push when `flaggedCount === pushedCount` or failing to send when `>` : breaks tests 1, 2, 3.
 * - Not starting a new 10-min window on the summary push: breaks test 2 (5th message at T+11m would push immediately).
 * - Dropping Redis `SET NX` claim in `runSocialAlertSummarySweep`: breaks test 6 (duplicate summary push).
 * - Removing per-key concurrency lock for batched scans: breaks test 7 (lost increments).
 */
describe("social alert per-contact window (#1029)", () => {
  const alerts = new Map<string, StoredAlert>();
  let alertSeq = 0;

  // Simulated Redis KV + list store with virtual expiration timestamps (ms).
  const redisStore = new Map<string, { value: string; expiresAt: number | null }>();
  const redisLists = new Map<string, string[]>();
  const recordedRedisKeys: string[] = [];
  const sentPushes: Array<{ platform: string; token: string; message: PushMessage }> = [];

  const isLive = (entry: { expiresAt: number | null } | undefined): boolean =>
    entry !== undefined && (entry.expiresAt === null || entry.expiresAt > Date.now());

  function bindMockRedisClient(redis: ReturnType<typeof getRedis>) {
    const setMock = redis.set as unknown as {
      mockImplementation: (fn: (key: string, value: string, ...rest: unknown[]) => Promise<string | null>) => void;
    };
    const getMock = redis.get as unknown as {
      mockImplementation: (fn: (key: string) => Promise<string | null>) => void;
    };
    (redis as unknown as { lrange?: (k: string, s: number, e: number) => Promise<string[]> }).lrange = vi.fn(
      async (k: string) => [...(redisLists.get(k) ?? [])],
    );
    const delMock = redis.del as unknown as {
      mockImplementation: (fn: (...keys: string[]) => Promise<number>) => void;
    };

    setMock.mockImplementation(async (key, value, ...rest) => {
      recordedRedisKeys.push(key);
      const exIdx = rest.indexOf("EX");
      const ttlSeconds = exIdx >= 0 ? Number(rest[exIdx + 1]) : null;
      const expiresAt = ttlSeconds !== null && Number.isFinite(ttlSeconds) ? Date.now() + ttlSeconds * 1000 : null;
      const nx = rest.includes("NX");
      if (nx && isLive(redisStore.get(key))) return null;
      if (rest.includes("XX") && !isLive(redisStore.get(key))) return null;
      redisStore.set(key, { value, expiresAt });
      return "OK";
    });
    getMock.mockImplementation(async (key) => {
      const entry = redisStore.get(key);
      if (!isLive(entry)) {
        redisStore.delete(key);
        return null;
      }
      return entry!.value;
    });
    delMock.mockImplementation(async (...keys) => {
      let n = 0;
      for (const k of keys) {
        if (redisStore.delete(k)) n += 1;
      }
      return n;
    });
    // Unit-suite mock wiring only; real Lua execution against Redis lives in
    // test/social-alert-window-redis.test.ts (enforced in CI via OSRA_REQUIRE_REDIS_TESTS=1).
    const evalMock = redis.eval as unknown as {
      mockImplementation: (fn: (script: string, numKeys: number, ...args: string[]) => Promise<unknown>) => void;
    };
    evalMock.mockImplementation(async (script, _numKeys, ...args) => {
      if (script === SOCIAL_WINDOW_ROLLOVER_SCRIPT) {
        const [key, expectedToken, nextPayload, ttlStr] = args;
        recordedRedisKeys.push(key!);
        const curEntry = redisStore.get(key!);
        const cur = isLive(curEntry) ? curEntry!.value : null;
        if (cur === null || cur.includes(expectedToken!)) {
          const ttlSeconds = Number(ttlStr);
          redisStore.set(key!, {
            value: nextPayload!,
            expiresAt: Number.isFinite(ttlSeconds) ? Date.now() + ttlSeconds * 1000 : null,
          });
          return 1;
        }
        return 0;
      }
      if (script === SOCIAL_PENDING_DEFER_SCRIPT) {
        const [key, deferredKey, sentinel, obsPayload] = args;
        const curEntry = redisStore.get(key!);
        const cur = isLive(curEntry) ? curEntry!.value : null;
        if (cur === sentinel) {
          const list = redisLists.get(deferredKey!) ?? [];
          list.push(obsPayload!);
          redisLists.set(deferredKey!, list);
          return "DEFERRED";
        }
        return cur ?? "";
      }
      if (script === SOCIAL_PENDING_PUBLISH_AND_PEEK_SCRIPT) {
        const [key, deferredKey, payload, ttlStr] = args;
        recordedRedisKeys.push(key!);
        const ttlSeconds = Number(ttlStr);
        redisStore.set(key!, {
          value: payload!,
          expiresAt: Number.isFinite(ttlSeconds) ? Date.now() + ttlSeconds * 1000 : null,
        });
        return [...(redisLists.get(deferredKey!) ?? [])];
      }
      if (script === SOCIAL_PENDING_ACK_SCRIPT) {
        const [deferredKey, countStr] = args;
        const n = Number(countStr);
        const list = redisLists.get(deferredKey!) ?? [];
        const rest = n > 0 ? list.slice(n) : list;
        if (rest.length === 0) redisLists.delete(deferredKey!);
        else redisLists.set(deferredKey!, rest);
        return rest.length;
      }
      if (script === SOCIAL_PENDING_RELEASE_SCRIPT) {
        const [key, sentinel] = args;
        const curEntry = redisStore.get(key!);
        const cur = isLive(curEntry) ? curEntry!.value : null;
        if (cur === sentinel) {
          redisStore.delete(key!);
          return 1;
        }
        return 0;
      }
      return null;
    });
  }

  const fakePushProvider: PushProvider = {
    platform: "android",
    async send(token, message) {
      sentPushes.push({ platform: "android", token, message });
      return { ok: true, messageId: `msg-${sentPushes.length}` };
    },
  };

  function installInMemoryStores() {
    alerts.clear();
    alertSeq = 0;
    redisStore.clear();
    redisLists.clear();
    recordedRedisKeys.length = 0;
    sentPushes.length = 0;

    bindMockRedisClient(getRedis());

    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.socialEvent.create.mockImplementation((async (args: { data: Record<string, unknown> }) => ({
      id: `se-${Math.random().toString(36).slice(2, 8)}`,
      ...args.data,
    })) as never);
    prismaMock.alert.create.mockImplementation((async (args: { data: Record<string, unknown> }) => {
      alertSeq += 1;
      const row: StoredAlert = {
        id: `alert-${alertSeq}`,
        childId: String(args.data.childId),
        deviceId: (args.data.deviceId as string | undefined) ?? null,
        severity: String(args.data.severity),
        category: String(args.data.category),
        title: String(args.data.title),
        body: String(args.data.body),
        metadata: structuredClone((args.data.metadata ?? {}) as Record<string, unknown>),
        attemptCount: Number(args.data.attemptCount ?? 1),
        acknowledged: false,
        createdAt: new Date(),
      };
      alerts.set(row.id, row);
      return structuredClone(row);
    }) as never);
    prismaMock.alert.findUnique.mockImplementation((async (args: { where: { id: string } }) => {
      const row = alerts.get(args.where.id);
      return row ? structuredClone(row) : null;
    }) as never);
    prismaMock.alert.findMany.mockImplementation((async () =>
      [...alerts.values()].map((row) => ({
        ...structuredClone(row),
        child: { familyId: CHILD.familyId, displayName: CHILD.displayName },
      }))) as never);
    prismaMock.alert.updateMany.mockImplementation((async (args: { where: { id: string; attemptCount?: number }; data: Record<string, unknown> }) => {
      const existing = alerts.get(args.where.id);
      if (!existing) return { count: 0 };
      if (args.where.attemptCount !== undefined && existing.attemptCount !== args.where.attemptCount) {
        return { count: 0 };
      }
      const next: StoredAlert = {
        ...existing,
        ...(args.data.severity !== undefined ? { severity: String(args.data.severity) } : {}),
        ...(args.data.attemptCount !== undefined ? { attemptCount: Number(args.data.attemptCount) } : {}),
        ...(args.data.body !== undefined ? { body: String(args.data.body) } : {}),
        ...(args.data.acknowledged !== undefined ? { acknowledged: Boolean(args.data.acknowledged) } : {}),
        ...(args.data.metadata !== undefined
          ? { metadata: structuredClone(args.data.metadata as Record<string, unknown>) }
          : {}),
      };
      alerts.set(next.id, next);
      return { count: 1 };
    }) as never);
    prismaMock.alert.update.mockImplementation((async (args: { where: { id: string }; data: Record<string, unknown> }) => {
      const existing = alerts.get(args.where.id);
      if (!existing) throw new Error(`Alert ${args.where.id} not found`);
      const next: StoredAlert = {
        ...existing,
        ...(args.data.severity !== undefined ? { severity: String(args.data.severity) } : {}),
        ...(args.data.attemptCount !== undefined ? { attemptCount: Number(args.data.attemptCount) } : {}),
        ...(args.data.body !== undefined ? { body: String(args.data.body) } : {}),
        ...(args.data.acknowledged !== undefined ? { acknowledged: Boolean(args.data.acknowledged) } : {}),
        ...(args.data.metadata !== undefined
          ? { metadata: structuredClone(args.data.metadata as Record<string, unknown>) }
          : {}),
      };
      alerts.set(next.id, next);
      return structuredClone(next);
    }) as never);

    // Wire mock push providers (android + ios tokens on parent-1) so every push call is captured.
    prismaMock.digestPrefs.findUnique.mockResolvedValue({ familyId: CHILD.familyId, pushEnabled: true });
    prismaMock.parent.findMany.mockResolvedValue([{ id: "parent-1" }]);
    prismaMock.parentPushToken.findMany.mockResolvedValue([
      { id: "tok-android", parentId: "parent-1", platform: "android", token: "fcm-tok-android" },
      { id: "tok-ios", parentId: "parent-1", platform: "ios", token: "fcm-tok-ios" },
    ]);
    const androidProvider: PushProvider = {
      platform: "android",
      send: vi.fn(async (token: string, message: PushMessage) => {
        sentPushes.push({ platform: "android", token, message });
        return { ok: true };
      }),
    };
    setPushProviders([androidProvider]);
  }

  /** Number of logical parent alert push fan-outs (2 tokens per alert push). */
  const pushRounds = () => sentPushes.length / 2;

  const aiFlagged = (severity: "info" | "warning" | "critical", concern: string) =>
    vi.fn(async () => ({
      ok: true,
      json: async () => ({ flagged: true, severity, categories: { [concern]: 0.92, safe: 0.05 } }),
    })) as unknown as typeof fetch;

  async function postScan(app: Awaited<ReturnType<typeof buildApp>>, body: Record<string, unknown>) {
    const raw = JSON.stringify(body);
    return app.inject({
      method: "POST",
      url: "/v1/social/scan",
      headers: { "content-type": "application/json", ...signV2(SECRET, raw, { caller: "ai-engine" }) },
      payload: raw,
    });
  }

  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-11-24T01:00:00.000Z"));
    resetPrismaMock();
    for (const r of MockRedis.instances) r.publish.mockClear();
    process.env.INTERNAL_HMAC_SECRET = SECRET;
    process.env.VAULT_KEY = VAULT_KEY;
    process.env.AI_ENGINE_URL = "http://ai-engine:8000";
    // #1139: this suite pins the per-contact window mechanics with a first-push budget of 1; the
    // default budget of 3 and grouped summaries are covered in the #1139 suite below.
    vi.stubEnv("SOCIAL_ALERT_FIRST_PUSHES", "1");
    installInMemoryStores();
  });

  afterEach(() => {
    setPushProviders(null);
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
  });

  it("11 flagged messages from 3 contacts in one window give 3 first pushes (#1139 budget), then ONE grouped summary", async () => {
    vi.stubEnv("SOCIAL_ALERT_FIRST_PUSHES", "3");
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiFlagged("warning", "cyberbullying"));

    // Tonight's exact shape: 5 from Alice, 5 from Bob, 1 from Charlie = 11 flagged messages.
    const schedule = [
      { contact: "Alice", count: 5 },
      { contact: "Bob", count: 5 },
      { contact: "Charlie", count: 1 },
    ];
    for (const group of schedule) {
      for (let i = 0; i < group.count; i += 1) {
        vi.setSystemTime(Date.now() + 5_000);
        const res = await postScan(app, {
          childId: CHILD.id,
          app: "WhatsApp",
          contact: group.contact,
          text: `mean message ${i} from ${group.contact}`,
        });
        expect(res.statusCode).toBe(200);
        expect(res.json().flagged).toBe(true);
      }
    }

    // All 11 stored in vault; 3 per-contact alert rows; 3 immediate pushes (Alice's first 3 use the budget).
    expect(prismaMock.socialEvent.create).toHaveBeenCalledTimes(11);
    expect(alerts.size).toBe(3);
    expect(pushRounds()).toBe(3);

    const byContact = new Map([...alerts.values()].map((a) => [String(a.metadata.contact), a]));
    expect(byContact.get("Alice")?.metadata.flaggedCount).toBe(5);
    expect(byContact.get("Alice")?.attemptCount).toBe(5);
    expect(byContact.get("Bob")?.metadata.flaggedCount).toBe(5);
    expect(byContact.get("Charlie")?.metadata.flaggedCount).toBe(1);

    // Advance past 10-minute window close and run summary sweep.
    vi.setSystemTime(Date.now() + SOCIAL_ALERT_WINDOW_MS + 10_000);
    const sweep = await runSocialAlertSummarySweep(new Date());

    // #1139: one summary push for the whole (child, app): Alice +2, Bob +5, Charlie +1.
    expect(sweep.pushed).toHaveLength(1);
    expect(sweep.pushed[0]!.delta).toBe(8);
    expect(pushRounds()).toBe(4); // 3 first pushes + 1 grouped summary
    expect(byContact.get("Alice") && alerts.get(byContact.get("Alice")!.id)?.metadata.summaryDelta).toBe(2);
    expect(byContact.get("Bob") && alerts.get(byContact.get("Bob")!.id)?.metadata.summaryDelta).toBe(5);
    expect([...alerts.values()].every((a) => a.metadata.summaryPending === false)).toBe(true);

    await app.close();
  });

  it("4 flagged messages from the same contact in 10 min give 1 push, in-place count=4, 1 summary push ('3 more'), and start a fresh window", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiFlagged("warning", "cyberbullying"));

    const timestamps: string[] = [];
    for (let i = 1; i <= 4; i += 1) {
      vi.setSystemTime(Date.now() + 30_000);
      timestamps.push(new Date().toISOString());
      const res = await postScan(app, {
        childId: CHILD.id,
        app: "WhatsApp",
        contact: "Sam",
        text: `bully line ${i}`,
      });
      expect(res.statusCode).toBe(200);
    }

    expect(alerts.size).toBe(1);
    expect(pushRounds()).toBe(1);
    const row = [...alerts.values()][0]!;
    expect(row.attemptCount).toBe(4);
    expect(row.metadata.flaggedCount).toBe(4);
    expect(row.metadata.pushedCount).toBe(1);
    expect(row.metadata.latestAt).toBe(timestamps[3]);
    const primaryEvent = await prismaMock.socialEvent.create.mock.results[0].value as { id: string };
    const latestEvent = await prismaMock.socialEvent.create.mock.results[3].value as { id: string };
    expect(row.metadata.primarySocialEventId).toBe(primaryEvent.id);
    expect(row.metadata.latestSourceEventId).toBe(latestEvent.id);
    expect(row.metadata.summaryPending).toBe(true);

    // Window closes -> 1 summary push for "3 more", and opens a fresh 10-min window.
    vi.setSystemTime(Date.now() + SOCIAL_ALERT_WINDOW_MS + 1_000);
    const sweep1 = await runSocialAlertSummarySweep(new Date());
    expect(sweep1.pushed).toHaveLength(1);
    expect(sweep1.pushed[0]!.delta).toBe(3);
    expect(pushRounds()).toBe(2);

    // 5th same-severity message 1 minute after the summary push stays inside the new 10-min window (no push yet).
    vi.setSystemTime(Date.now() + 60_000);
    const fifth = await postScan(app, {
      childId: CHILD.id,
      app: "WhatsApp",
      contact: "Sam",
      text: "bully line 5",
    });
    expect(fifth.statusCode).toBe(200);
    expect(alerts.size).toBe(1);
    expect(alerts.get(row.id)?.metadata.flaggedCount).toBe(5);
    expect(alerts.get(row.id)?.metadata.primarySocialEventId).toBe(primaryEvent.id);
    expect(pushRounds()).toBe(2); // still 2 — no >1 push per 10 min

    // Second window closes -> 1 summary push for "1 more".
    vi.setSystemTime(Date.now() + SOCIAL_ALERT_WINDOW_MS + 1_000);
    const sweep2 = await runSocialAlertSummarySweep(new Date());
    expect(sweep2.pushed).toHaveLength(1);
    expect(sweep2.pushed[0]!.delta).toBe(1);
    expect(pushRounds()).toBe(3);

    await app.close();
  });

  it("#1061: with SOCIAL_ALERT_PUSH_EVERY_MESSAGE=true three messages from one contact give three pushes and one card counting 3", async () => {
    // Mutant this row kills: dropping the per-message push (or leaving `pushedCount` behind) turns this into
    // the default behaviour — 1 push, summaryPending true, and a later summary push of "2 more".
    vi.stubEnv("SOCIAL_ALERT_PUSH_EVERY_MESSAGE", "true");
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiFlagged("warning", "cyberbullying"));

    for (let i = 1; i <= 3; i += 1) {
      vi.setSystemTime(Date.now() + 30_000);
      const res = await postScan(app, {
        childId: CHILD.id,
        app: "WhatsApp",
        contact: "Sam",
        text: `own-model line ${i}`,
      });
      expect(res.statusCode).toBe(200);
    }

    // One card per contact, counting every message (#1030 aggregation untouched)…
    expect(alerts.size).toBe(1);
    const row = [...alerts.values()][0]!;
    expect(row.metadata.flaggedCount).toBe(3);
    expect(row.metadata.contact).toBe("Sam");
    // …but a push for each message, and nothing left pending for the summary sweep.
    expect(pushRounds()).toBe(3);
    expect(row.metadata.pushedCount).toBe(3);
    expect(row.metadata.summaryPending).toBe(false);

    vi.setSystemTime(Date.now() + SOCIAL_ALERT_WINDOW_MS + 1_000);
    const sweep = await runSocialAlertSummarySweep(new Date());
    expect(sweep.pushed).toHaveLength(0);
    expect(pushRounds()).toBe(3);

    // The lock-screen rule still holds on every one of those pushes: no contact name, no message text.
    for (const sent of sentPushes) {
      const body = JSON.stringify(sent.message);
      expect(body).not.toContain("Sam");
      expect(body).not.toContain("own-model line");
    }

    await app.close();
  });

  it("#1061: a severity step-up still pushes once, not twice, with the switch on", async () => {
    // Claude 13:37: `applyObservationsToAlert` already pushes on a bypass, so the per-message push must not
    // repeat it. Mutant: drop `&& !applied.bypassed` from the call site and this reads 3.
    vi.stubEnv("SOCIAL_ALERT_PUSH_EVERY_MESSAGE", "true");
    const app = await buildApp(socialRoutes, "/v1/social");
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({ ok: true, json: async () => ({ flagged: true, severity: "warning", categories: { cyberbullying: 0.9, safe: 0.1 } }) })
      .mockResolvedValueOnce({ ok: true, json: async () => ({ flagged: true, severity: "critical", categories: { self_harm: 0.95, safe: 0.05 } }) });
    vi.stubGlobal("fetch", fetchMock as unknown as typeof fetch);

    for (const text of ["warning line", "critical line"]) {
      vi.setSystemTime(Date.now() + 30_000);
      const res = await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "Sam", text });
      expect(res.statusCode).toBe(200);
    }

    expect(alerts.size).toBe(1);
    expect(pushRounds()).toBe(2);
    await app.close();
  });

  it("#1061: the switch is off unless it is exactly true", async () => {
    // A stray value must not turn it on in a definition someone copied by hand.
    vi.stubEnv("SOCIAL_ALERT_PUSH_EVERY_MESSAGE", "1");
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiFlagged("warning", "cyberbullying"));
    for (let i = 1; i <= 2; i += 1) {
      vi.setSystemTime(Date.now() + 30_000);
      await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "Sam", text: `off line ${i}` });
    }
    expect(pushRounds()).toBe(1);
    await app.close();
  });

  it("higher severity mid-window bypasses the throttle and pushes immediately without an extra summary push", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");

    // 1. Warning pushes immediately.
    vi.stubGlobal("fetch", aiFlagged("warning", "cyberbullying"));
    await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "Dana", text: "you are ugly" });
    expect(pushRounds()).toBe(1);

    // 2. Second warning updates in place without pushing.
    vi.setSystemTime(Date.now() + 30_000);
    await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "Dana", text: "nobody likes you" });
    expect(pushRounds()).toBe(1);

    // 3. Critical self-harm mid-window bypasses immediately on the same alert row.
    vi.setSystemTime(Date.now() + 30_000);
    vi.stubGlobal("fetch", aiFlagged("critical", "self_harm"));
    await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "Dana", text: "kill yourself" });

    expect(alerts.size).toBe(1);
    expect(pushRounds()).toBe(2);
    const row = [...alerts.values()][0]!;
    expect(row.severity).toBe("critical");
    expect(row.metadata.flaggedCount).toBe(3);
    expect(row.metadata.pushedCount).toBe(3);
    expect(row.metadata.pushedSeverity).toBe("critical");
    expect(row.metadata.summaryPending).toBe(false);
    expect(row.metadata.concernTypes).toEqual(expect.arrayContaining(["cyberbullying", "self_harm"]));

    // Window closes with no further messages -> 0 summary push (already pushed at critical bypass).
    vi.setSystemTime(Date.now() + SOCIAL_ALERT_WINDOW_MS + 5_000);
    const sweep = await runSocialAlertSummarySweep(new Date());
    expect(sweep.pushed).toHaveLength(0);
    expect(pushRounds()).toBe(2);

    await app.close();
  });

  it("groups empty/unknown contact into a deterministic salted bucket and omits contact from bodyParams", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiFlagged("warning", "cyberbullying"));

    await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "", text: "first unknown" });
    vi.setSystemTime(Date.now() + 15_000);
    await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "   ", text: "second unknown" });

    expect(alerts.size).toBe(1);
    expect(pushRounds()).toBe(1);
    const row = [...alerts.values()][0]!;
    expect(row.metadata.contact).toBe("");
    expect(row.metadata.flaggedCount).toBe(2);
    expect(typeof row.metadata.contactKey).toBe("string");
    expect((row.metadata.contactKey as string).length).toBe(32);
    expect((row.metadata.bodyParams as Record<string, unknown>)).toEqual({ app: "WhatsApp" });

    await app.close();
  });

  it("never leaks raw contact names or message text into Redis keys or push payloads", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    const secretContact = "Layla Al-Mansoori";
    const secretText = "secret-bullying-payload-xyz";

    // Confirm salted key format and child isolation.
    const keyChild1 = socialAlertThrottleKey("child-1", "WhatsApp", secretContact);
    const keyChild2 = socialAlertThrottleKey("child-2", "WhatsApp", secretContact);
    expect(keyChild1).toMatch(/^social:alert:child-1:whatsapp:[a-f0-9]{32}$/);
    expect(keyChild1).not.toContain("layla");
    expect(keyChild1).not.toContain("Layla");
    expect(socialContactKey("child-1", secretContact)).not.toBe(socialContactKey("child-2", secretContact));
    expect(keyChild1).not.toBe(keyChild2);

    vi.stubGlobal("fetch", aiFlagged("warning", "cyberbullying"));
    await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: secretContact, text: secretText });
    vi.setSystemTime(Date.now() + 15_000);
    await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: secretContact, text: `${secretText}-2` });
    vi.setSystemTime(Date.now() + 15_000);
    vi.stubGlobal("fetch", aiFlagged("critical", "self_harm"));
    await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: secretContact, text: `${secretText}-3` });
    vi.setSystemTime(Date.now() + 15_000);
    await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: secretContact, text: `${secretText}-4` });
    vi.setSystemTime(Date.now() + SOCIAL_ALERT_WINDOW_MS + 5_000);
    await runSocialAlertSummarySweep(new Date());

    // Initial push + critical bypass push + summary push = 3 rounds (6 token sends).
    expect(pushRounds()).toBe(3);
    for (const p of sentPushes) {
      const serialized = JSON.stringify(p.message);
      expect(serialized).not.toContain(secretContact);
      expect(serialized).not.toContain("Layla");
      expect(serialized).not.toContain(secretText);
    }
    for (const k of recordedRedisKeys) {
      expect(k.toLowerCase()).not.toContain("layla");
      expect(k.toLowerCase()).not.toContain("mansoori");
      expect(k.toLowerCase()).not.toContain("secret-bullying");
    }

    await app.close();
  });

  it("summary sweep is idempotent across concurrent/repeated ticks via Redis SET NX claim", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiFlagged("warning", "cyberbullying"));

    await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "Omar", text: "msg 1" });
    vi.setSystemTime(Date.now() + 10_000);
    await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "Omar", text: "msg 2" });

    vi.setSystemTime(Date.now() + SOCIAL_ALERT_WINDOW_MS + 10_000);
    const [r1, r2] = await Promise.all([
      runSocialAlertSummarySweep(new Date()),
      runSocialAlertSummarySweep(new Date()),
    ]);
    expect(r1.pushed.length + r2.pushed.length).toBe(1);
    expect(pushRounds()).toBe(2); // 1 initial + exactly 1 summary

    await app.close();
  });

  it("handles a concurrent same-contact batch without losing increments", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiFlagged("warning", "cyberbullying"));

    const res = await postScan(app, {
      items: [
        { childId: CHILD.id, app: "WhatsApp", contact: "BatchContact", text: "batch 1" },
        { childId: CHILD.id, app: "WhatsApp", contact: "BatchContact", text: "batch 2" },
        { childId: CHILD.id, app: "WhatsApp", contact: "BatchContact", text: "batch 3" },
      ],
    });
    expect(res.statusCode).toBe(200);
    expect(alerts.size).toBe(1);
    expect(pushRounds()).toBe(1);
    const row = [...alerts.values()][0]!;
    expect(row.attemptCount).toBe(3);
    expect(row.metadata.flaggedCount).toBe(3);
    expect(row.metadata.summaryPending).toBe(true);

    await app.close();
  });

  it("retries optimistic CAS when a second replica increments attemptCount concurrently", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiFlagged("warning", "cyberbullying"));

    await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "ReplicaRace", text: "msg 1" });
    const row = [...alerts.values()][0]!;

    // Simulate another ECS replica incrementing attemptCount 1 -> 2 right before our CAS write.
    const origUpdateMany = prismaMock.alert.updateMany.getMockImplementation()!;
    let injectedRace = false;
    prismaMock.alert.updateMany.mockImplementation((async (args: { where: { id: string; attemptCount?: number }; data: Record<string, unknown> }) => {
      if (!injectedRace) {
        injectedRace = true;
        const live = alerts.get(row.id)!;
        alerts.set(row.id, {
          ...live,
          attemptCount: 2,
          metadata: { ...live.metadata, flaggedCount: 2, summaryPending: true },
        });
        return { count: 0 };
      }
      return origUpdateMany(args);
    }) as never);

    vi.setSystemTime(Date.now() + 10_000);
    const res = await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "ReplicaRace", text: "msg 3" });
    expect(res.statusCode).toBe(200);
    expect(alerts.get(row.id)?.attemptCount).toBe(3);
    expect(alerts.get(row.id)?.metadata.flaggedCount).toBe(3);

    await app.close();
  });

  // Mutant (Codex #1033 review): replacing the atomic rollover in socialAlertSummary.ts with an
  // unconditional redis.set(...) overwrites the active key back to alert-1 and makes scan 4
  // increment alert-1 instead of alert-2.
  it("delayed summary sweep preserves a newer active contact window instead of overwriting it", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiFlagged("warning", "cyberbullying"));

    // Window 1: scan 1 + scan 2 accumulate on alert-1 (summaryPending = true).
    await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "DelayedSweep", text: "msg 1" });
    vi.setSystemTime(Date.now() + 30_000);
    await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "DelayedSweep", text: "msg 2" });
    expect(alerts.size).toBe(1);
    const alert1Id = [...alerts.keys()][0]!;

    // Advance just past Window 1 expiry; scan 3 arrives BEFORE the delayed sweep runs -> opens alert-2.
    vi.setSystemTime(Date.now() + SOCIAL_ALERT_WINDOW_MS + 5_000);
    await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "DelayedSweep", text: "msg 3" });
    expect(alerts.size).toBe(2);
    const alert2Id = [...alerts.keys()].find((id) => id !== alert1Id)!;

    const key = socialAlertThrottleKey(CHILD.id, "WhatsApp", "DelayedSweep");
    const beforeSweep = JSON.parse((await getRedis().get(key))!) as { alertId: string };
    expect(beforeSweep.alertId).toBe(alert2Id);

    // Delayed summary sweep for alert-1 runs now.
    const sweep = await runSocialAlertSummarySweep(new Date());
    expect(sweep.pushed.map((p) => p.alertId)).toEqual([alert1Id]);

    // Active Redis key MUST still reference alert-2, never reverted to alert-1.
    const afterSweep = JSON.parse((await getRedis().get(key))!) as { alertId: string };
    expect(afterSweep.alertId).toBe(alert2Id);

    // Scan 4 arriving inside Window 2 MUST increment alert-2 (leaving alert-1 at 2).
    vi.setSystemTime(Date.now() + 15_000);
    await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "DelayedSweep", text: "msg 4" });
    expect(alerts.get(alert1Id)?.metadata.flaggedCount).toBe(2);
    expect(alerts.get(alert2Id)?.metadata.flaggedCount).toBe(2);
    expect(alerts.get(alert2Id)?.attemptCount).toBe(2);

    await app.close();
  });

  // Mutant (Codex #1033 review 7117292252): reverting the pending backoff wait to the old 75 ms cap
  // drops the second replica's observation when the first replica's insert takes 150 ms, leaving count = 1.
  it("preserves both observations across two independently loaded replicas when the first insert takes 150 ms", async () => {
    const origCreate = prismaMock.alert.create.getMockImplementation()!;
    let delayedOnce = false;
    prismaMock.alert.create.mockImplementation((async (args: { data: Record<string, unknown> }) => {
      if (!delayedOnce) {
        delayedOnce = true;
        await new Promise((resolve) => setTimeout(resolve, 150));
      }
      return origCreate(args);
    }) as never);

    // Load two independent module graphs so each replica owns a separate in-process `keyLocks` map.
    vi.resetModules();
    const replica1Redis = await import("../src/redis.js");
    const replica1Notify = await import("../src/lib/push/notify.js");
    const replica1 = await import("../src/lib/socialAlertWindow.js");
    bindMockRedisClient(replica1Redis.getRedis());
    replica1Notify.setPushProviders([fakePushProvider]);

    vi.resetModules();
    const replica2Redis = await import("../src/redis.js");
    const replica2Notify = await import("../src/lib/push/notify.js");
    const replica2 = await import("../src/lib/socialAlertWindow.js");
    bindMockRedisClient(replica2Redis.getRedis());
    replica2Notify.setPushProviders([fakePushProvider]);

    expect(replica1.recordFlaggedSocialAlert).not.toBe(replica2.recordFlaggedSocialAlert);

    const baseInput = {
      childId: CHILD.id,
      familyId: CHILD.familyId,
      childName: CHILD.displayName,
      appName: "WhatsApp",
      contact: "TwoReplica150ms",
      category: "social_concern" as const,
      severity: "warning" as const,
      concernTypes: ["cyberbullying"],
    };

    const p1 = replica1.recordFlaggedSocialAlert(baseInput);
    await new Promise((resolve) => setTimeout(resolve, 15));
    const p2 = replica2.recordFlaggedSocialAlert(baseInput);
    await Promise.all([p1, p2]);

    expect(alerts.size).toBe(1);
    const row = [...alerts.values()][0]!;
    expect(row.attemptCount).toBe(2);
    expect(row.metadata.flaggedCount).toBe(2);
    expect(row.metadata.summaryPending).toBe(true);
    expect(pushRounds()).toBe(1);
  });

  // Mutant: removing the atomic deferred-queue handoff loses replica 2's observation whenever replica 1's
  // insert exceeds `pendingWaitMs`, leaving count = 1 and missing severity escalation.
  it("hands off to the deferred queue across two independent replicas when insert latency exceeds pendingWaitMs", async () => {
    const origCreate = prismaMock.alert.create.getMockImplementation()!;
    let delayedOnce = false;
    prismaMock.alert.create.mockImplementation((async (args: { data: Record<string, unknown> }) => {
      if (!delayedOnce) {
        delayedOnce = true;
        await new Promise((resolve) => setTimeout(resolve, 120));
      }
      return origCreate(args);
    }) as never);

    vi.resetModules();
    const replica1Redis = await import("../src/redis.js");
    const replica1Notify = await import("../src/lib/push/notify.js");
    const replica1 = await import("../src/lib/socialAlertWindow.js");
    bindMockRedisClient(replica1Redis.getRedis());
    replica1Notify.setPushProviders([fakePushProvider]);

    vi.resetModules();
    const replica2Redis = await import("../src/redis.js");
    const replica2Notify = await import("../src/lib/push/notify.js");
    const replica2 = await import("../src/lib/socialAlertWindow.js");
    bindMockRedisClient(replica2Redis.getRedis());
    replica2Notify.setPushProviders([fakePushProvider]);

    const p1 = replica1.recordFlaggedSocialAlert({
      childId: CHILD.id,
      familyId: CHILD.familyId,
      childName: CHILD.displayName,
      appName: "WhatsApp",
      contact: "TwoReplicaDeferred",
      category: "social_concern",
      severity: "warning",
      concernTypes: ["cyberbullying"],
      pendingWaitMs: 30,
    });
    await new Promise((resolve) => setTimeout(resolve, 10));
    const p2 = replica2.recordFlaggedSocialAlert({
      childId: CHILD.id,
      familyId: CHILD.familyId,
      childName: CHILD.displayName,
      appName: "WhatsApp",
      contact: "TwoReplicaDeferred",
      category: "social_concern",
      severity: "critical",
      concernTypes: ["self_harm"],
      pendingWaitMs: 30,
    });
    await Promise.all([p1, p2]);

    expect(alerts.size).toBe(1);
    const row = [...alerts.values()][0]!;
    expect(row.attemptCount).toBe(2);
    expect(row.metadata.flaggedCount).toBe(2);
    expect(row.severity).toBe("critical");
    expect(row.metadata.pushedSeverity).toBe("critical");
    expect(pushRounds()).toBe(2);
  });

  // Mutant (Codex #1033 review 7118711880): deleting deferred entries before the DB update commits
  // loses the deferred observation when the update rejects once, leaving count=1 and deferred list empty;
  // omitting appliedDeferredIds causes post-commit replay to double-count to 3.
  it("keeps deferred observations recoverable on pre-commit DB failure and replays idempotently after post-commit failure", async () => {
    const origCreate = prismaMock.alert.create.getMockImplementation()!;
    const origUpdateMany = prismaMock.alert.updateMany.getMockImplementation()!;
    let delayedOnce = false;
    let failUpdateOnce = true;

    prismaMock.alert.create.mockImplementation((async (args: { data: Record<string, unknown> }) => {
      if (!delayedOnce) {
        delayedOnce = true;
        await new Promise((resolve) => setTimeout(resolve, 120));
      }
      return origCreate(args);
    }) as never);
    prismaMock.alert.updateMany.mockImplementation((async (args: { where: { id: string; attemptCount?: number }; data: Record<string, unknown> }) => {
      if (failUpdateOnce) {
        failUpdateOnce = false;
        throw new Error("transient DB failure before commit");
      }
      return origUpdateMany(args);
    }) as never);

    vi.resetModules();
    const r1Redis = await import("../src/redis.js");
    const r1Notify = await import("../src/lib/push/notify.js");
    const replica1 = await import("../src/lib/socialAlertWindow.js");
    bindMockRedisClient(r1Redis.getRedis());
    r1Notify.setPushProviders([fakePushProvider]);

    vi.resetModules();
    const r2Redis = await import("../src/redis.js");
    const r2Notify = await import("../src/lib/push/notify.js");
    const replica2 = await import("../src/lib/socialAlertWindow.js");
    bindMockRedisClient(r2Redis.getRedis());
    r2Notify.setPushProviders([fakePushProvider]);

    const p1 = replica1.recordFlaggedSocialAlert({
      childId: CHILD.id,
      familyId: CHILD.familyId,
      childName: CHILD.displayName,
      appName: "WhatsApp",
      contact: "CommitBoundary",
      category: "social_concern",
      severity: "warning",
      concernTypes: ["cyberbullying"],
      pendingWaitMs: 25,
    });
    await new Promise((resolve) => setTimeout(resolve, 10));
    const p2 = replica2.recordFlaggedSocialAlert({
      childId: CHILD.id,
      familyId: CHILD.familyId,
      childName: CHILD.displayName,
      appName: "WhatsApp",
      contact: "CommitBoundary",
      category: "social_concern",
      severity: "warning",
      concernTypes: ["cyberbullying"],
      pendingWaitMs: 25,
    });

    await expect(p2).resolves.toMatchObject({ throttled: true });
    await expect(p1).rejects.toThrow("transient DB failure before commit");

    expect(alerts.size).toBe(1);
    const createdRow = [...alerts.values()][0]!;
    const claimId = String(createdRow.metadata.windowClaimId);
    expect(claimId.length).toBeGreaterThan(0);
    const deferredKey = socialAlertDeferredKey(socialAlertThrottleKey(CHILD.id, "WhatsApp", "CommitBoundary"), claimId);
    expect(createdRow.attemptCount).toBe(1);
    expect(redisLists.get(deferredKey)).toHaveLength(1);
    const savedDeferredRaw = [...(redisLists.get(deferredKey) ?? [])];

    // Pre-commit recovery: replay commits count = 2 and trims Redis.
    await replayDeferredSocialObservations(createdRow as never, { familyId: CHILD.familyId, childName: CHILD.displayName });
    expect(alerts.get(createdRow.id)?.attemptCount).toBe(2);
    expect(alerts.get(createdRow.id)?.metadata.flaggedCount).toBe(2);
    expect(redisLists.get(deferredKey)).toBeUndefined();

    // Post-commit ack loss: re-inject the same deferred entry and replay -> count stays 2 (never 3).
    redisLists.set(deferredKey, savedDeferredRaw);
    await replayDeferredSocialObservations(alerts.get(createdRow.id)! as never, {
      familyId: CHILD.familyId,
      childName: CHILD.displayName,
    });
    expect(alerts.get(createdRow.id)?.attemptCount).toBe(2);
    expect(alerts.get(createdRow.id)?.metadata.flaggedCount).toBe(2);
    expect(redisLists.get(deferredKey)).toBeUndefined();
  });

  // Mutant (Codex #1033 review 7119141081): acknowledging the deferred queue even when all 6 CAS
  // attempts return count=0 drops the deferred observation (DB=1, queue=0) instead of returning retryable.
  it("preserves deferred entries and returns retryable when all 6 CAS attempts conflict", async () => {
    const origCreate = prismaMock.alert.create.getMockImplementation()!;
    const origUpdateMany = prismaMock.alert.updateMany.getMockImplementation()!;
    let delayedOnce = false;
    let remainingConflicts = 6;

    prismaMock.alert.create.mockImplementation((async (args: { data: Record<string, unknown> }) => {
      if (!delayedOnce) {
        delayedOnce = true;
        await new Promise((resolve) => setTimeout(resolve, 120));
      }
      return origCreate(args);
    }) as never);
    prismaMock.alert.updateMany.mockImplementation((async (args: { where: { id: string; attemptCount?: number }; data: Record<string, unknown> }) => {
      if (remainingConflicts > 0) {
        remainingConflicts -= 1;
        return { count: 0 };
      }
      return origUpdateMany(args);
    }) as never);

    vi.resetModules();
    const r1Redis = await import("../src/redis.js");
    const r1Notify = await import("../src/lib/push/notify.js");
    const replica1 = await import("../src/lib/socialAlertWindow.js");
    bindMockRedisClient(r1Redis.getRedis());
    r1Notify.setPushProviders([fakePushProvider]);

    vi.resetModules();
    const r2Redis = await import("../src/redis.js");
    const r2Notify = await import("../src/lib/push/notify.js");
    const replica2 = await import("../src/lib/socialAlertWindow.js");
    bindMockRedisClient(r2Redis.getRedis());
    r2Notify.setPushProviders([fakePushProvider]);

    const p1 = replica1.recordFlaggedSocialAlert({
      childId: CHILD.id,
      familyId: CHILD.familyId,
      childName: CHILD.displayName,
      appName: "WhatsApp",
      contact: "SixConflicts",
      category: "social_concern",
      severity: "warning",
      concernTypes: ["cyberbullying"],
      pendingWaitMs: 25,
    });
    await new Promise((resolve) => setTimeout(resolve, 10));
    const p2 = replica2.recordFlaggedSocialAlert({
      childId: CHILD.id,
      familyId: CHILD.familyId,
      childName: CHILD.displayName,
      appName: "WhatsApp",
      contact: "SixConflicts",
      category: "social_concern",
      severity: "warning",
      concernTypes: ["cyberbullying"],
      pendingWaitMs: 25,
    });

    const [res1, res2] = await Promise.all([p1, p2]);
    expect(res2.throttled).toBe(true);
    expect(res1.retryable).toBe(true);
    expect(remainingConflicts).toBe(0);

    const row = [...alerts.values()][0]!;
    const deferredKey = socialAlertDeferredKey(
      socialAlertThrottleKey(CHILD.id, "WhatsApp", "SixConflicts"),
      String(row.metadata.windowClaimId),
    );
    expect(row.attemptCount).toBe(1);
    expect(redisLists.get(deferredKey)).toHaveLength(1);

    // Once conflicts subside, replay commits count = 2 and clears the queue.
    await replayDeferredSocialObservations(row as never, { familyId: CHILD.familyId, childName: CHILD.displayName });
    expect(alerts.get(row.id)?.attemptCount).toBe(2);
    expect(alerts.get(row.id)?.metadata.flaggedCount).toBe(2);
    expect(redisLists.get(deferredKey)).toBeUndefined();
  });

  // Mutant (Codex #1033 review 7119167276): sharing one contact-wide deferred key lets an expired older
  // row steal a newer window's deferred observation when visited first (ending old=2, current=1, queued=0).
  it("binds deferred replay to the originating window in both candidate orders ([old, current] and [current, old])", async () => {
    const throttleKey = socialAlertThrottleKey(CHILD.id, "WhatsApp", "WindowBound");
    const contactKey = socialContactKey(CHILD.id, "WindowBound");

    for (const order of ["old-first", "current-first"] as const) {
      alerts.clear();
      redisLists.clear();
      const oldClaim = `claim-old-${order}`;
      const curClaim = `claim-cur-${order}`;
      const oldRow: StoredAlert = {
        id: `alert-old-${order}`,
        childId: CHILD.id,
        deviceId: null,
        severity: "warning",
        category: "social_concern",
        title: "Social concern",
        body: "1 concerning message",
        attemptCount: 1,
        acknowledged: false,
        createdAt: new Date("2026-11-24T00:40:00.000Z"),
        metadata: {
          app: "WhatsApp",
          contact: "WindowBound",
          contactKey,
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
      };
      const curRow: StoredAlert = {
        id: `alert-cur-${order}`,
        childId: CHILD.id,
        deviceId: null,
        severity: "warning",
        category: "social_concern",
        title: "Social concern",
        body: "1 concerning message",
        attemptCount: 1,
        acknowledged: false,
        createdAt: new Date("2026-11-24T01:00:00.000Z"),
        metadata: {
          app: "WhatsApp",
          contact: "WindowBound",
          contactKey,
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
      };
      alerts.set(oldRow.id, oldRow);
      alerts.set(curRow.id, curRow);

      const curDeferKey = socialAlertDeferredKey(throttleKey, curClaim);
      redisLists.set(curDeferKey, [
        JSON.stringify({
          id: `obs-${order}`,
          claimId: curClaim,
          severity: "warning",
          concernTypes: ["cyberbullying"],
          observedAt: "2026-11-24T01:00:05.000Z",
        }),
      ]);

      const ordered = order === "old-first" ? [oldRow, curRow] : [curRow, oldRow];
      prismaMock.alert.findMany.mockResolvedValueOnce(
        ordered.map((r) => ({ ...r, child: { familyId: CHILD.familyId, displayName: CHILD.displayName } })),
      );

      await runSocialAlertSummarySweep(new Date("2026-11-24T01:01:00.000Z"));
      expect(alerts.get(oldRow.id)?.attemptCount).toBe(1);
      expect(alerts.get(curRow.id)?.attemptCount).toBe(2);
      expect(alerts.get(curRow.id)?.metadata.flaggedCount).toBe(2);
      expect(redisLists.get(curDeferKey)).toBeUndefined();
    }
  });
  // ── #1139 alert grouping (Karim 25 Nov): first 3 flagged messages per (child, app) push, the rest are
  // grouped into one summary per window; critical and step-ups always push; delivery fields move only on
  // a real push. These rows run with the default budget (the suite pins 1 for the #1029 mechanics).
  describe("#1139 first-push budget and grouped summaries", () => {
    beforeEach(() => {
      vi.stubEnv("SOCIAL_ALERT_FIRST_PUSHES", "");
    });

    it("5 flagged messages from one contact give 3 pushes, then 1 grouped summary for the other 2", async () => {
      // Mutant: budget ignored (old 1-per-window) reads 1 push; budget never exhausted reads 5.
      const app = await buildApp(socialRoutes, "/v1/social");
      vi.stubGlobal("fetch", aiFlagged("warning", "cyberbullying"));
      for (let i = 1; i <= 5; i += 1) {
        vi.setSystemTime(Date.now() + 20_000);
        const res = await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "Sam", text: `line ${i}` });
        expect(res.statusCode).toBe(200);
      }
      expect(alerts.size).toBe(1);
      expect(pushRounds()).toBe(3);
      const row = [...alerts.values()][0]!;
      expect(row.metadata.flaggedCount).toBe(5);
      expect(row.metadata.pushedCount).toBe(3);
      expect(row.metadata.summaryPending).toBe(true);
      expect(row.metadata.pushDeliverySeq).toBe(3);
      const idAfterThird = row.metadata.pushDeliveryId;
      expect(typeof idAfterThird).toBe("string");
      const historyAfterThird = row.metadata.pushDeliveries as Array<{ id: string; seq: number; createdAt: string }>;
      expect(historyAfterThird).toHaveLength(3);
      expect(historyAfterThird.map((entry) => entry.seq)).toEqual([1, 2, 3]);
      expect(historyAfterThird[2]!.id).toBe(idAfterThird);

      vi.setSystemTime(Date.now() + socialAlertWindowMs() + 1_000);
      const sweep = await runSocialAlertSummarySweep(new Date());
      expect(sweep.pushed).toHaveLength(1);
      expect(sweep.pushed[0]!.delta).toBe(2);
      expect(pushRounds()).toBe(4);
      const after = alerts.get(row.id)!;
      expect(after.metadata.pushDeliverySeq).toBe(4);
      expect(after.metadata.pushDeliveryId).not.toBe(idAfterThird);
      expect(after.metadata.pushDeliveries).toEqual([
        ...historyAfterThird,
        { id: after.metadata.pushDeliveryId, seq: 4, createdAt: new Date().toISOString() },
      ]);

      // A repeated tick sends nothing more.
      const again = await runSocialAlertSummarySweep(new Date());
      expect(again.pushed).toHaveLength(0);
      expect(pushRounds()).toBe(4);
      await app.close();
    });

    it("retains the newest ten delivery entries in issue order on one alert card", async () => {
      // Mutant: retaining only latest or failing to cap the list loses the expected ten entries.
      vi.stubEnv("SOCIAL_ALERT_FIRST_PUSHES", "12");
      const app = await buildApp(socialRoutes, "/v1/social");
      vi.stubGlobal("fetch", aiFlagged("warning", "cyberbullying"));
      try {
        const issued: Array<{ id: unknown; seq: number; createdAt: string }> = [];
        for (let seq = 1; seq <= 12; seq += 1) {
          vi.setSystemTime(Date.now() + 10_000);
          const res = await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "Sam", text: `line ${seq}` });
          expect(res.statusCode).toBe(200);
          const row = [...alerts.values()][0]!;
          expect(row.metadata.pushDeliverySeq).toBe(seq);
          issued.push({ id: row.metadata.pushDeliveryId, seq, createdAt: new Date().toISOString() });
        }
        expect(alerts.size).toBe(1);
        expect(pushRounds()).toBe(12);
        expect(new Set(issued.map((entry) => entry.id)).size).toBe(12);
        expect([...alerts.values()][0]!.metadata.pushDeliveries).toEqual(issued.slice(-10));
      } finally {
        await app.close();
      }
    });

    it("a silent in-place update keeps the delivery fields unchanged", async () => {
      // Mutant: setting pushDeliveryId on every update makes the parent re-notify for a silent count bump.
      const app = await buildApp(socialRoutes, "/v1/social");
      vi.stubGlobal("fetch", aiFlagged("warning", "cyberbullying"));
      for (let i = 1; i <= 3; i += 1) {
        vi.setSystemTime(Date.now() + 20_000);
        await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "Sam", text: `line ${i}` });
      }
      const row = [...alerts.values()][0]!;
      const before = { id: row.metadata.pushDeliveryId, seq: row.metadata.pushDeliverySeq };
      vi.setSystemTime(Date.now() + 20_000);
      await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "Sam", text: "line 4" });
      const after = alerts.get(row.id)!;
      expect(after.metadata.flaggedCount).toBe(4);
      expect(after.metadata.pushDeliveryId).toBe(before.id);
      expect(after.metadata.pushDeliverySeq).toBe(before.seq);
      expect(pushRounds()).toBe(3);
      await app.close();
    });

    it("the budget spans contacts of one app, and a card created over budget carries sequence zero", async () => {
      // Mutant: leaving all fields absent makes the Parent planner treat this as a legacy push.
      const app = await buildApp(socialRoutes, "/v1/social");
      vi.stubGlobal("fetch", aiFlagged("warning", "cyberbullying"));
      for (const contact of ["A", "B", "C", "D"]) {
        vi.setSystemTime(Date.now() + 10_000);
        await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact, text: `hello from ${contact}` });
      }
      expect(alerts.size).toBe(4);
      expect(pushRounds()).toBe(3);
      const byContact = new Map([...alerts.values()].map((a) => [String(a.metadata.contact), a]));
      const d = byContact.get("D")!;
      expect(d.metadata.pushedCount).toBe(0);
      expect(d.metadata.summaryPending).toBe(true);
      expect(d.metadata.pushDeliveryId).toBeUndefined();
      expect(d.metadata.pushDeliverySeq).toBe(0);
      expect(d.metadata.pushDeliveries).toBeUndefined();
      expect(byContact.get("A")!.metadata.pushDeliverySeq).toBe(1);
      await app.close();
    });

    it("two concurrent sweeps issue one child/app summary and keep folded silent cards silent", async () => {
      // Mutant: claiming only individual contact rows lets each sweep issue a separate delivery.
      const app = await buildApp(socialRoutes, "/v1/social");
      vi.stubGlobal("fetch", aiFlagged("warning", "cyberbullying"));
      try {
        for (const contact of ["A", "A", "A", "A", "B", "C"]) {
          vi.setSystemTime(Date.now() + 10_000);
          const res = await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact, text: `msg from ${contact}` });
          expect(res.statusCode).toBe(200);
        }
        expect(pushRounds()).toBe(3);
        vi.setSystemTime(Date.now() + socialAlertWindowMs() + 1_000);
        const sweeps = await Promise.all([runSocialAlertSummarySweep(new Date()), runSocialAlertSummarySweep(new Date())]);
        const deliveries = sweeps.flatMap((sweep) => sweep.pushed);
        expect(deliveries).toHaveLength(1);
        expect(deliveries[0]!.delta).toBe(3);
        expect(pushRounds()).toBe(4);
        const foldedSilent = [...alerts.values()].find((row) => row.metadata.contact === "B")!;
        expect(foldedSilent.metadata.summaryPending).toBe(false);
        expect(foldedSilent.metadata.summaryGroupedInto).toBe(deliveries[0]!.alertId);
        expect(foldedSilent.metadata.pushDeliverySeq).toBe(0);
        expect(foldedSilent.metadata.pushDeliveryId).toBeUndefined();
        expect(foldedSilent.metadata.pushDeliveries).toBeUndefined();
      } finally {
        await app.close();
      }
    });

    it("several closed windows of one child and app give ONE grouped summary push", async () => {
      // Mutant: pushing per row reads 2 summary pushes here.
      const app = await buildApp(socialRoutes, "/v1/social");
      vi.stubGlobal("fetch", aiFlagged("warning", "cyberbullying"));
      // A: 3 messages (all 3 budget slots), then B: 2 messages (over budget).
      for (const contact of ["A", "A", "A", "A", "B", "B"]) {
        vi.setSystemTime(Date.now() + 10_000);
        await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact, text: `msg from ${contact}` });
      }
      expect(pushRounds()).toBe(3);
      vi.setSystemTime(Date.now() + socialAlertWindowMs() + 1_000);
      const sweep = await runSocialAlertSummarySweep(new Date());
      expect(sweep.pushed).toHaveLength(1);
      expect(sweep.pushed[0]!.delta).toBe(3); // A +1, B +2
      expect(sweep.pushed[0]!.groupedAlertIds).toHaveLength(1);
      expect(pushRounds()).toBe(4);
      const rows = [...alerts.values()];
      expect(rows.every((r) => r.metadata.summaryPending === false)).toBe(true);
      const delivered = rows.filter((r) => r.id === sweep.pushed[0]!.alertId);
      const folded = rows.filter((r) => r.id !== sweep.pushed[0]!.alertId);
      expect(delivered[0]!.metadata.summaryGroupedInto).toBeUndefined();
      expect(folded[0]!.metadata.summaryGroupedInto).toBe(sweep.pushed[0]!.alertId);
      await app.close();
    });

    it("another app has its own budget", async () => {
      const app = await buildApp(socialRoutes, "/v1/social");
      vi.stubGlobal("fetch", aiFlagged("warning", "cyberbullying"));
      for (let i = 1; i <= 4; i += 1) {
        vi.setSystemTime(Date.now() + 10_000);
        await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "Sam", text: `wa ${i}` });
      }
      vi.setSystemTime(Date.now() + 10_000);
      await postScan(app, { childId: CHILD.id, app: "Instagram", contact: "Sam", text: "ig 1" });
      expect(pushRounds()).toBe(4);
      await app.close();
    });

    it("a critical message pushes at once even when the budget is used up", async () => {
      // Mutant: dropping the critical bypass on a new card leaves this at 3.
      const app = await buildApp(socialRoutes, "/v1/social");
      vi.stubGlobal("fetch", aiFlagged("warning", "cyberbullying"));
      for (const contact of ["A", "B", "C"]) {
        vi.setSystemTime(Date.now() + 10_000);
        await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact, text: `warn ${contact}` });
      }
      expect(pushRounds()).toBe(3);
      vi.setSystemTime(Date.now() + 10_000);
      vi.stubGlobal("fetch", aiFlagged("critical", "self_harm"));
      await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "D", text: "critical line" });
      expect(pushRounds()).toBe(4);
      const d = [...alerts.values()].find((a) => a.metadata.contact === "D")!;
      expect(d.metadata.pushedCount).toBe(1);
      expect(d.metadata.pushDeliverySeq).toBe(1);
      await app.close();
    });

    it("SOCIAL_ALERT_FIRST_PUSHES and SOCIAL_ALERT_SUMMARY_MINUTES are read and clamped", async () => {
      expect(socialAlertFirstPushes({})).toBe(3);
      expect(socialAlertFirstPushes({ SOCIAL_ALERT_FIRST_PUSHES: "0" })).toBe(1);
      expect(socialAlertFirstPushes({ SOCIAL_ALERT_FIRST_PUSHES: "99" })).toBe(20);
      expect(socialAlertFirstPushes({ SOCIAL_ALERT_FIRST_PUSHES: "abc" })).toBe(3);
      expect(socialAlertSummaryMinutes({})).toBe(10);
      expect(socialAlertSummaryMinutes({ SOCIAL_ALERT_SUMMARY_MINUTES: "0" })).toBe(1);
      expect(socialAlertSummaryMinutes({ SOCIAL_ALERT_SUMMARY_MINUTES: "120" })).toBe(60);
      expect(socialAlertWindowMs({ SOCIAL_ALERT_SUMMARY_MINUTES: "2" })).toBe(120_000);

      // A 2-minute cadence: the summary is due after 2 minutes, not 10.
      vi.stubEnv("SOCIAL_ALERT_SUMMARY_MINUTES", "2");
      vi.stubEnv("SOCIAL_ALERT_FIRST_PUSHES", "1");
      const app = await buildApp(socialRoutes, "/v1/social");
      vi.stubGlobal("fetch", aiFlagged("warning", "cyberbullying"));
      for (let i = 1; i <= 2; i += 1) {
        vi.setSystemTime(Date.now() + 5_000);
        await postScan(app, { childId: CHILD.id, app: "WhatsApp", contact: "Sam", text: `c ${i}` });
      }
      expect(pushRounds()).toBe(1);
      vi.setSystemTime(Date.now() + 2 * 60_000 + 1_000);
      const sweep = await runSocialAlertSummarySweep(new Date());
      expect(sweep.pushed).toHaveLength(1);
      expect(pushRounds()).toBe(2);
      await app.close();
    });
  });
});
