import { beforeEach, describe, expect, it, vi } from "vitest";
import { prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});
const pushes: Array<{ id: string; seq: unknown }> = [];
const pushedPayloads: string[] = [];
vi.mock("../src/lib/push/notify.js", () => ({
  notifyParentsOfAlert: vi.fn(async (_familyId: string, alert: { id: string; metadata: Record<string, unknown> }) => {
    pushes.push({ id: alert.id, seq: alert.metadata?.pushDeliverySeq });
    pushedPayloads.push(JSON.stringify(alert));
  }),
}));
vi.mock("../src/realtime/gateway.js", () => ({ publishFamilyEvent: vi.fn(async () => undefined) }));

const { recordBlockedAttempt } = await import("../src/lib/blockedAttemptWindow.js");
const { runBlockedAttemptSummarySweep } = await import("../src/jobs/blockedAttemptSummary.js");
const { getRedis } = await import("../src/redis.js");

type Row = {
  id: string; childId: string; deviceId: string | null; category: string; dedupeKey: string | null;
  attemptCount: number; metadata: Record<string, unknown>; createdAt: Date; acknowledged: boolean;
  heldDuringSetup: boolean; severity: string; title: string; body: string;
  child?: { familyId: string; displayName: string };
};

let clock = Date.parse("2026-11-26T18:00:00.000Z");
let rows: Row[] = [];
const kv = new Map<string, { v: string; exp: number }>();
const env = { NODE_ENV: "test" } as NodeJS.ProcessEnv;
const at = (minutes: number) => new Date(clock + minutes * 60_000);

function installRedis(now: () => number) {
  const redis = getRedis() as unknown as Record<string, unknown>;
  const live = (k: string) => {
    const e = kv.get(k);
    if (e && e.exp <= now()) kv.delete(k);
    return kv.get(k);
  };
  redis.get = vi.fn(async (k: string) => live(k)?.v ?? null);
  redis.set = vi.fn(async (k: string, v: string, ...args: unknown[]) => {
    const exIdx = args.indexOf("EX");
    const ttl = exIdx >= 0 ? Number(args[exIdx + 1]) : 1e9;
    const exists = live(k) !== undefined;
    if (args.includes("NX") && exists) return null;
    if (args.includes("XX") && !exists) return null;
    kv.set(k, { v, exp: now() + ttl * 1000 });
    return "OK";
  });
  redis.del = vi.fn(async (...keys: string[]) => keys.reduce((n, k) => n + (kv.delete(k) ? 1 : 0), 0));
}

let nowMs = clock;
function installPrisma() {
  const a = prismaMock.alert as unknown as Record<string, ReturnType<typeof vi.fn>>;
  a.findFirst.mockImplementation(async ({ where }: { where: Record<string, unknown> }) => {
    const dk = where.dedupeKey as string | { startsWith: string };
    const match = rows.filter((r) => r.childId === (where.childId ?? r.childId) && r.category === where.category &&
      (typeof dk === "string" ? r.dedupeKey === dk : r.dedupeKey?.startsWith(dk.startsWith)));
    return match.sort((x, y) => y.createdAt.getTime() - x.createdAt.getTime())[0] ?? null;
  });
  a.create.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => {
    const row = { id: `a${rows.length + 1}`, acknowledged: false, createdAt: new Date(nowMs), ...data } as Row;
    rows.push(row);
    return row;
  });
  a.updateMany.mockImplementation(async ({ where, data }: { where: { id: string; attemptCount: number }; data: Partial<Row> }) => {
    const row = rows.find((r) => r.id === where.id && r.attemptCount === where.attemptCount);
    if (!row) return { count: 0 };
    Object.assign(row, data);
    return { count: 1 };
  });
  a.findUnique.mockImplementation(async ({ where }: { where: { id: string } }) => rows.find((r) => r.id === where.id) ?? null);
  a.findMany.mockImplementation(async () =>
    rows.map((r) => ({ ...r, child: { familyId: "fam-1", displayName: "Kid" } })).sort((x, y) => y.createdAt.getTime() - x.createdAt.getTime()));
}

function attempt(category: "web_threat" | "app_blocked", minutes: number, extra: Partial<Parameters<typeof recordBlockedAttempt>[0]> = {}) {
  nowMs = at(minutes).getTime();
  return recordBlockedAttempt({
    childId: "child-1", familyId: "fam-1", childName: "Kid", deviceId: "dev-1", timeZone: "Asia/Qatar",
    category, severity: "info", title: "Blocked", body: "Blocked",
    metadata: category === "app_blocked" ? { packageId: "com.zhiliaoapp.musically", appName: "TikTok" } : { reason: "blocked_domain" },
    siteNames: false, now: at(minutes), env, ...extra,
  });
}

describe("#1222 blocked attempts follow the #1139 grouped-alert rule", () => {
  beforeEach(() => {
    resetPrismaMock();
    rows = [];
    pushes.length = 0;
    pushedPayloads.length = 0;
    kv.clear();
    clock = Date.parse("2026-11-26T18:00:00.000Z");
    installRedis(() => nowMs);
    installPrisma();
  });

  it("a burst of 5 inside 10 minutes: 3 pushes, then one grouped summary", async () => {
    for (const m of [0, 1, 2, 3, 4]) await attempt("app_blocked", m);
    expect(rows).toHaveLength(1);
    expect(rows[0].attemptCount).toBe(5);
    expect(pushes).toHaveLength(3);
    expect(rows[0].metadata.latestAt).toBe(at(4).toISOString());
    expect(rows[0].metadata.blockGroup).toMatchObject({ pushedCount: 3, summaryPending: true, summaryDueAt: at(12).toISOString() });

    nowMs = at(11).getTime();
    expect((await runBlockedAttemptSummarySweep(at(11), env)).pushed).toHaveLength(0);
    nowMs = at(12).getTime();
    const run = await runBlockedAttemptSummarySweep(at(12), env);
    expect(run.pushed).toEqual([expect.objectContaining({ alertId: rows[0].id, delta: 2 })]);
    expect(pushes).toHaveLength(4);
    expect(rows[0].metadata.blockGroup).toMatchObject({ pushedCount: 5, summaryPending: false });
    expect(rows[0].metadata.pushDeliverySeq).toBe(4);
  });

  it("Ahmed's row: two blocked-site attempts 10 minutes apart are two alerts, the second one pushed", async () => {
    await attempt("web_threat", 0);
    await attempt("web_threat", 10);
    expect(rows).toHaveLength(2);
    expect(rows.map((r) => r.attemptCount)).toEqual([1, 1]);
    expect(pushes.map((p) => p.id)).toEqual(["a1", "a2"]);
    // Names off: the run key carries no host.
    expect(rows[1].dedupeKey).toMatch(/^grp:web::2026-11-26:\d+$/);
  });

  it("an attempt after the budget is spent starts silent (sequence 0) and is summarised later", async () => {
    for (const m of [0, 1, 2]) await attempt("app_blocked", m);
    await attempt("app_blocked", 3, { metadata: { packageId: "com.roblox.client", appName: "Roblox" } });
    expect(rows).toHaveLength(2);
    expect(pushes).toHaveLength(3);
    expect(rows[1].metadata.pushDeliverySeq).toBe(0);
    expect(rows[1].metadata.blockGroup).toMatchObject({ summaryPending: true, summaryDueAt: at(13).toISOString() });
  });

  it("the day follows the family's zone: midnight UTC does not split a Doha evening, Doha midnight does", async () => {
    clock = Date.parse("2026-11-26T23:55:00.000Z"); // 02:55 in Doha, 27 Nov
    await attempt("app_blocked", 0);
    await attempt("app_blocked", 6); // 00:01 UTC on the 27th: same Doha day, same run
    expect(rows).toHaveLength(1);
    rows = [];
    kv.clear();
    clock = Date.parse("2026-11-26T20:55:00.000Z"); // 23:55 in Doha
    await attempt("app_blocked", 0);
    await attempt("app_blocked", 6); // 00:01 in Doha: a new day, a new row
    expect(rows).toHaveLength(2);
    expect(rows[0].dedupeKey).toContain(":2026-11-26:");
    expect(rows[1].dedupeKey).toContain(":2026-11-27:");
  });

  it("a lost-response retry with the same device count changes nothing", async () => {
    await attempt("app_blocked", 0, { producerKey: "app:com.x:2026-11-26", producerAttemptCount: 1 });
    const again = await attempt("app_blocked", 1, { producerKey: "app:com.x:2026-11-26", producerAttemptCount: 1 });
    expect(again.retry).toBe(true);
    expect(rows[0].attemptCount).toBe(1);
    expect(pushes).toHaveLength(1);
    const next = await attempt("app_blocked", 2, { producerKey: "app:com.x:2026-11-26", producerAttemptCount: 2 });
    expect(next.retry).toBe(false);
    expect(rows[0].attemptCount).toBe(2);
  });

  type Entry = { at: string; site?: string; app?: string };
  const entries = (row: Row) => ((row.metadata.blockGroup as Record<string, unknown>).attempts ?? []) as Entry[];

  it("lists every accepted attempt as its own entry, newest first (lead 00:35: each attempt still listed)", async () => {
    for (const m of [0, 1, 2, 3, 4]) await attempt("app_blocked", m);
    expect(rows).toHaveLength(1);
    expect(entries(rows[0])).toEqual([4, 3, 2, 1, 0].map((m) => ({ at: at(m).toISOString(), app: "TikTok" })));
    // The summary sweep keeps the list.
    nowMs = at(12).getTime();
    await runBlockedAttemptSummarySweep(at(12), env);
    expect(entries(rows[0])).toHaveLength(5);
  });

  it("an entry names the site only when site names are on; names off shows the time alone", async () => {
    await attempt("web_threat", 0, { metadata: { domain: "https://www.example.test/path" }, siteNames: true });
    await attempt("web_threat", 20, { metadata: { domain: "example.test" } });
    expect(entries(rows[0])).toEqual([{ at: at(0).toISOString(), site: "www.example.test" }]);
    expect(entries(rows[1])).toEqual([{ at: at(20).toISOString() }]);
  });

  it("overlapping copies of one attempt count and push once (Codex #1228 finding 1)", async () => {
    const key = { producerKey: "app:com.x:2026-11-26" };
    await attempt("app_blocked", 0, { ...key, producerAttemptCount: 1 });
    const [a, b] = await Promise.all([
      attempt("app_blocked", 1, { ...key, producerAttemptCount: 2 }),
      attempt("app_blocked", 1, { ...key, producerAttemptCount: 2 }),
    ]);
    expect([a.retry, b.retry].sort()).toEqual([false, true]);
    expect(rows).toHaveLength(1);
    expect(rows[0].attemptCount).toBe(2);
    expect(pushes).toHaveLength(2);
    expect(entries(rows[0])).toHaveLength(2);
  });

  it("a failed write releases the claim, so the phone's retry still records the attempt", async () => {
    const key = { producerKey: "app:com.x:2026-11-26" };
    await attempt("app_blocked", 0, { ...key, producerAttemptCount: 1 });
    const a = prismaMock.alert as unknown as Record<string, ReturnType<typeof vi.fn>>;
    a.updateMany.mockRejectedValueOnce(new Error("synthetic write failure"));
    await expect(attempt("app_blocked", 1, { ...key, producerAttemptCount: 2 })).rejects.toThrow("synthetic write failure");
    expect(rows[0].attemptCount).toBe(1);
    const retried = await attempt("app_blocked", 2, { ...key, producerAttemptCount: 2 });
    expect(retried.retry).toBe(false);
    expect(rows[0].attemptCount).toBe(2);
  });

  it("a distinct attempt with a lower device count that arrives later is still counted (Codex #1228 [Sat] point 2)", async () => {
    const key = { producerKey: "app:com.x:2026-11-26" };
    await attempt("app_blocked", 0, { ...key, producerAttemptCount: 1 });
    await attempt("app_blocked", 1, { ...key, producerAttemptCount: 3 }); // count 3 arrives first (reconnect)
    const late = await attempt("app_blocked", 2, { ...key, producerAttemptCount: 2 });
    expect(late.retry).toBe(false);
    expect(rows).toHaveLength(1);
    expect(rows[0].attemptCount).toBe(3);
    expect(entries(rows[0])).toHaveLength(3);
    // The very same attempt again is a retry.
    const again = await attempt("app_blocked", 3, { ...key, producerAttemptCount: 2 });
    expect(again.retry).toBe(true);
    expect(rows[0].attemptCount).toBe(3);
    expect(entries(rows[0])).toHaveLength(3);
  });

  it("keeps a normal app label intact, including the letter s (Codex #1228 [Sat] point 3)", async () => {
    await attempt("app_blocked", 0, { metadata: { packageId: "com.supercell.clashofclans", appName: "Clash  of\tClans s" } });
    await attempt("app_blocked", 20, { metadata: { packageId: "com.snapchat.android", appName: "Snapchat" } });
    expect(entries(rows[0])).toEqual([{ at: at(0).toISOString(), app: "Clash of Clans s" }]);
    expect(entries(rows[1])).toEqual([{ at: at(20).toISOString(), app: "Snapchat" }]);
  });

  it("an earlier attempt that finishes later never moves the group backwards (Codex #1228 finding 2)", async () => {
    await attempt("app_blocked", 0);
    await attempt("app_blocked", 5);
    await attempt("app_blocked", 3); // received at 3, finished after the one received at 5
    expect(rows).toHaveLength(1);
    expect(rows[0].attemptCount).toBe(3);
    expect(rows[0].metadata.latestAt).toBe(at(5).toISOString());
    expect((rows[0].metadata.blockGroup as Record<string, unknown>).latestAt).toBe(at(5).toISOString());
    expect(entries(rows[0]).map((e) => e.at)).toEqual([5, 3, 0].map((m) => at(m).toISOString()));
  });

  it("names off: no stored receipt key, alert field or push names the site (osra-security#88)", async () => {
    // The producer's own key carries the host; the route has already redacted metadata, title and body.
    const site = "secret-site.test";
    const key = { producerKey: `web:www.${site}:2026-11-26` };
    await attempt("web_threat", 0, { ...key, producerAttemptCount: 1 });
    await attempt("web_threat", 1, { ...key, producerAttemptCount: 2 });
    const retry = await attempt("web_threat", 2, { ...key, producerAttemptCount: 2 });
    expect(retry.retry).toBe(true);
    for (let i = 3; i <= 5; i += 1) await attempt("web_threat", i, { ...key, producerAttemptCount: i });
    clock += 30 * 60_000;
    nowMs = clock;
    await runBlockedAttemptSummarySweep(at(0), env);

    expect(rows.length).toBeGreaterThan(0);
    expect(pushes.length).toBeGreaterThan(3); // three pushes and the grouped summary
    expect(kv.size).toBeGreaterThan(0);
    const keys = [...kv.keys()];
    expect(keys.some((k) => k.startsWith("blocked:claim:"))).toBe(true);
    expect(keys.some((k) => k.startsWith("blocked:seen:"))).toBe(true);
    for (const k of keys) {
      expect(k).not.toContain(site);
      expect(k).not.toContain("secret");
    }
    for (const r of rows) expect(JSON.stringify(r)).not.toContain(site);
    for (const p of pushedPayloads) expect(p).not.toContain(site);
  });

  it("the receipt fingerprint is keyed: stable for one secret, different under another, never the raw key", async () => {
    const { blockedProducerFingerprint, blockedSeenKey, blockedClaimKey } = await import("../src/lib/blockedAttemptWindow.js");
    const a = { VAULT_KEY: "k-one", NODE_ENV: "test" } as NodeJS.ProcessEnv;
    const b = { VAULT_KEY: "k-two", NODE_ENV: "test" } as NodeJS.ProcessEnv;
    const fp = blockedProducerFingerprint("dev-1", "web_threat", "web:www.secret-site.test:2026-11-26", a);
    expect(fp).toMatch(/^[0-9a-f]{32}$/);
    expect(blockedProducerFingerprint("dev-1", "web_threat", "web:www.secret-site.test:2026-11-26", a)).toBe(fp);
    expect(blockedProducerFingerprint("dev-1", "web_threat", "web:www.secret-site.test:2026-11-26", b)).not.toBe(fp);
    expect(blockedProducerFingerprint("dev-2", "web_threat", "web:www.secret-site.test:2026-11-26", a)).not.toBe(fp);
    expect(blockedSeenKey("dev-1", "web_threat", "web:www.secret-site.test:2026-11-26", a)).toBe(`blocked:seen:dev-1:web_threat:${fp}`);
    expect(blockedClaimKey("dev-1", "web_threat", "web:www.secret-site.test:2026-11-26", 4, a)).toBe(`blocked:claim:dev-1:web_threat:${fp}:4`);
    expect(() => blockedProducerFingerprint("dev-1", "web_threat", "x", { NODE_ENV: "production" } as NodeJS.ProcessEnv)).toThrow(
      /VAULT_KEY or INTERNAL_HMAC_SECRET/,
    );
  });
});
