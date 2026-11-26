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
vi.mock("../src/lib/push/notify.js", () => ({
  notifyParentsOfAlert: vi.fn(async (_familyId: string, alert: { id: string; metadata: Record<string, unknown> }) => {
    pushes.push({ id: alert.id, seq: alert.metadata?.pushDeliverySeq });
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
});
