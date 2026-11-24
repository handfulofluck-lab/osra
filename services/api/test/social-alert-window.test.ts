import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { signV2 } from "../src/lib/internalAuth.js";
import { socialRoutes } from "../src/routes/social.js";
import {
  SOCIAL_ALERT_WINDOW_MS,
  SOCIAL_PENDING_DEFER_SCRIPT,
  SOCIAL_PENDING_PUBLISH_AND_DRAIN_SCRIPT,
  SOCIAL_PENDING_RELEASE_SCRIPT,
  socialAlertThrottleKey,
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
      if (script === SOCIAL_PENDING_PUBLISH_AND_DRAIN_SCRIPT) {
        const [key, deferredKey, payload, ttlStr] = args;
        recordedRedisKeys.push(key!);
        const ttlSeconds = Number(ttlStr);
        redisStore.set(key!, {
          value: payload!,
          expiresAt: Number.isFinite(ttlSeconds) ? Date.now() + ttlSeconds * 1000 : null,
        });
        const items = redisLists.get(deferredKey!) ?? [];
        redisLists.delete(deferredKey!);
        return items;
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
    installInMemoryStores();
  });

  afterEach(() => {
    setPushProviders(null);
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
  });

  it("11 flagged messages from 3 contacts in one window give 3 pushes, then summary pushes only for contacts with >1", async () => {
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

    // All 11 stored in vault; 3 per-contact alert rows created; 3 immediate pushes (1 per contact).
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

    // Only Alice (+4) and Bob (+4) get summary pushes; Charlie had no extra messages after push 1.
    expect(sweep.pushed).toHaveLength(2);
    expect(sweep.pushed.map((p) => p.delta).sort()).toEqual([4, 4]);
    expect(pushRounds()).toBe(5); // 3 initial + 2 summaries
    expect(byContact.get("Alice") && alerts.get(byContact.get("Alice")!.id)?.metadata.summaryDelta).toBe(4);
    expect(byContact.get("Charlie") && alerts.get(byContact.get("Charlie")!.id)?.metadata.summaryPushed).toBe(false);

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
    expect(pushRounds()).toBe(2); // still 2 — no >1 push per 10 min

    // Second window closes -> 1 summary push for "1 more".
    vi.setSystemTime(Date.now() + SOCIAL_ALERT_WINDOW_MS + 1_000);
    const sweep2 = await runSocialAlertSummarySweep(new Date());
    expect(sweep2.pushed).toHaveLength(1);
    expect(sweep2.pushed[0]!.delta).toBe(1);
    expect(pushRounds()).toBe(3);

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
});