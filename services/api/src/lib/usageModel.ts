import { prisma } from "../db.js";
import { getRedis } from "../redis.js";

/**
 * Phase 2c (ADR-0013): the durable usage model.
 *
 *  - `AppUsageDaily` (child × device × UTC day × app → minutes) is written incrementally at ingestion
 *    and reconciled from `ActivityEvent` by the nightly rollup, so a weekly report is correct after a
 *    Redis flush and after raw events age out. `app = "*"` is the device-reported day total.
 *  - `WebVisit` is one row per URL event, so browsing history is a query, not a JSON scan.
 *  - Retention: raw rows (`ActivityEvent`, `WebVisit`, `SocialEvent`, `LocationPing`) are deleted after
 *    `RETENTION_DAYS` (default 90); rollups after `ROLLUP_RETENTION_DAYS` (default 365).
 *  - Erasure: `eraseChildData()` is the one place that lists every child-scoped table and Redis key,
 *    so a GDPR delete leaves zero rows and no orphaned keys.
 *
 * All instants are bound from JS (never `NOW()` in SQL — issue #53), and `day` is the UTC calendar day.
 */

/** Device-reported day total (telemetry `totalMinutes`), kept apart from per-app rows. */
export const DEVICE_TOTAL_APP = "*";

const MS_PER_DAY = 86_400_000;

export function retentionDays(env: NodeJS.ProcessEnv = process.env): number {
  const n = Number(env.RETENTION_DAYS ?? 90);
  return Number.isInteger(n) && n >= 7 ? n : 90;
}

export function rollupRetentionDays(env: NodeJS.ProcessEnv = process.env): number {
  const n = Number(env.ROLLUP_RETENTION_DAYS ?? 365);
  return Number.isInteger(n) && n >= retentionDays(env) ? n : 365;
}

/** UTC calendar day of an instant, as a Date at 00:00:00Z (what a `@db.Date` column stores). */
export function utcDay(at: Date = new Date()): Date {
  return new Date(Date.UTC(at.getUTCFullYear(), at.getUTCMonth(), at.getUTCDate()));
}

export function dayKey(day: Date): string {
  return day.toISOString().slice(0, 10);
}

type IncomingEvent = { ts?: string; type: string; payload: Record<string, unknown> };

/** Minutes per (day, app) from app_usage events, ignoring live heartbeats; hosts from url events. */
export function bucketEvents(events: IncomingEvent[]): {
  usage: Map<string, { day: Date; app: string; minutes: number }>;
  visits: Array<{ ts: Date; domain: string; url: string; blocked: boolean; category: string }>;
} {
  const usage = new Map<string, { day: Date; app: string; minutes: number }>();
  const visits: Array<{ ts: Date; domain: string; url: string; blocked: boolean; category: string }> = [];
  for (const e of events) {
    const p = e.payload ?? {};
    const ts = e.ts ? new Date(e.ts) : new Date();
    if (Number.isNaN(ts.getTime())) continue;
    if (e.type === "app_usage") {
      if (p.live === true) continue;
      const minutes = typeof p.minutes === "number" && Number.isFinite(p.minutes) ? Math.max(0, Math.round(p.minutes)) : 0;
      if (minutes === 0) continue;
      const app = typeof p.app === "string" && p.app ? p.app.slice(0, 200) : "unknown";
      const day = utcDay(ts);
      const key = `${dayKey(day)}|${app}`;
      const cur = usage.get(key);
      if (cur) cur.minutes += minutes;
      else usage.set(key, { day, app, minutes });
    } else if (e.type === "url") {
      const url = typeof p.url === "string" ? p.url.slice(0, 2048) : "";
      let domain = typeof p.domain === "string" && p.domain ? p.domain : "";
      if (!domain && url) {
        try { domain = new URL(url).hostname; } catch { domain = ""; }
      }
      if (!domain) domain = "unknown";
      visits.push({
        ts,
        domain: domain.toLowerCase().slice(0, 253),
        url,
        blocked: p.blocked === true,
        category: typeof p.category === "string" ? p.category.slice(0, 64) : "",
      });
    }
  }
  return { usage, visits };
}

/** Upsert-increment one (child, device, day, app) row. */
async function addMinutes(childId: string, deviceId: string, day: Date, app: string, minutes: number): Promise<void> {
  await prisma.appUsageDaily.upsert({
    where: { childId_deviceId_day_app: { childId, deviceId, day, app } },
    create: { childId, deviceId, day, app, minutes },
    update: { minutes: { increment: minutes } },
  });
}

/** Ingestion hook: fold a device's activity batch into the rollup tables. Best-effort per row. */
export async function recordActivityUsage(childId: string, deviceId: string, events: IncomingEvent[]): Promise<{ usageRows: number; visits: number }> {
  const { usage, visits } = bucketEvents(events);
  for (const { day, app, minutes } of usage.values()) await addMinutes(childId, deviceId, day, app, minutes);
  if (visits.length > 0) {
    await prisma.webVisit.createMany({ data: visits.map((v) => ({ childId, deviceId, ...v })) });
  }
  return { usageRows: usage.size, visits: visits.length };
}

/** Telemetry hook: the device-reported running total for the day (delta windows accumulate, #31). */
export async function recordDeviceTotal(childId: string, deviceId: string, minutes: number, at: Date = new Date()): Promise<void> {
  if (!(minutes > 0)) return;
  await addMinutes(childId, deviceId, utcDay(at), DEVICE_TOTAL_APP, Math.round(minutes));
}

/**
 * Today's screen time for a child from the durable table: the device totals when any device reported
 * one, else the per-app sum. Used when the Redis `usage:child:<id>:<day>` cache is missing (flushed,
 * restarted, or expired) — the number must not drop to 0 because a cache did.
 */
export async function screenTimeTodayFromDb(childId: string, at: Date = new Date()): Promise<number> {
  const rows = await prisma.appUsageDaily.findMany({ where: { childId, day: utcDay(at) }, select: { app: true, minutes: true } });
  const totals = rows.filter((r) => r.app === DEVICE_TOTAL_APP);
  const pick = totals.length > 0 ? totals : rows;
  return pick.reduce((n, r) => n + r.minutes, 0);
}

export interface UsageDay {
  day: string;
  minutes: number;
  apps: Array<{ app: string; minutes: number }>;
}

/** Per-day series for the trailing `days` days (today included), oldest first; days with no data are 0. */
export async function usageSeries(childId: string, days: number, at: Date = new Date()): Promise<UsageDay[]> {
  const today = utcDay(at);
  const from = new Date(today.getTime() - (days - 1) * MS_PER_DAY);
  const rows = await prisma.appUsageDaily.findMany({ where: { childId, day: { gte: from, lte: today } } });
  const byDay = new Map<string, UsageDay>();
  for (let i = 0; i < days; i += 1) {
    const d = dayKey(new Date(from.getTime() + i * MS_PER_DAY));
    byDay.set(d, { day: d, minutes: 0, apps: [] });
  }
  const appTotals = new Map<string, Map<string, number>>();
  const deviceTotals = new Map<string, number>();
  for (const r of rows) {
    const d = dayKey(r.day);
    if (r.app === DEVICE_TOTAL_APP) {
      deviceTotals.set(d, (deviceTotals.get(d) ?? 0) + r.minutes);
      continue;
    }
    const m = appTotals.get(d) ?? new Map<string, number>();
    m.set(r.app, (m.get(r.app) ?? 0) + r.minutes);
    appTotals.set(d, m);
  }
  for (const [d, entry] of byDay) {
    const apps = [...(appTotals.get(d) ?? new Map()).entries()].sort((a, b) => b[1] - a[1]).map(([app, minutes]) => ({ app, minutes }));
    const perAppSum = apps.reduce((n, a) => n + a.minutes, 0);
    entry.apps = apps;
    entry.minutes = deviceTotals.has(d) ? deviceTotals.get(d)! : perAppSum;
  }
  return [...byDay.values()];
}

/** Browsing history, newest first. */
export async function webHistory(childId: string, days: number, limit: number, opts: { blockedOnly?: boolean; domain?: string } = {}, at: Date = new Date()) {
  const since = new Date(at.getTime() - days * MS_PER_DAY);
  const rows = await prisma.webVisit.findMany({
    where: {
      childId,
      ts: { gte: since },
      ...(opts.blockedOnly ? { blocked: true } : {}),
      ...(opts.domain ? { domain: opts.domain.toLowerCase() } : {}),
    },
    orderBy: { ts: "desc" },
    take: limit,
  });
  return rows;
}

/**
 * Nightly reconciliation of one UTC day: recompute every child's per-app minutes for `day` from
 * `ActivityEvent` and overwrite the rollup rows (idempotent). Device totals (`*`) come from telemetry
 * and are left alone. Returns the number of rows written.
 */
export async function rollupDay(day: Date): Promise<number> {
  const from = utcDay(day);
  const to = new Date(from.getTime() + MS_PER_DAY);
  const events = await prisma.activityEvent.findMany({
    where: { type: "app_usage", ts: { gte: from, lt: to } },
    select: { childId: true, deviceId: true, ts: true, type: true, payload: true },
  });
  // (child, device) → bucket
  const groups = new Map<string, { childId: string; deviceId: string; events: IncomingEvent[] }>();
  for (const e of events) {
    const deviceId = e.deviceId ?? "";
    const key = `${e.childId}|${deviceId}`;
    const g = groups.get(key) ?? { childId: e.childId, deviceId, events: [] };
    g.events.push({ ts: e.ts.toISOString(), type: e.type, payload: (e.payload ?? {}) as Record<string, unknown> });
    groups.set(key, g);
  }
  let written = 0;
  for (const g of groups.values()) {
    const { usage } = bucketEvents(g.events);
    for (const { app, minutes } of usage.values()) {
      await prisma.appUsageDaily.upsert({
        where: { childId_deviceId_day_app: { childId: g.childId, deviceId: g.deviceId, day: from, app } },
        create: { childId: g.childId, deviceId: g.deviceId, day: from, app, minutes },
        update: { minutes },
      });
      written += 1;
    }
  }
  return written;
}

export interface RetentionResult {
  activityEvents: number;
  webVisits: number;
  socialEvents: number;
  locationPings: number;
  usageDays: number;
}

/** Delete raw rows older than the retention window and rollups older than theirs. */
export async function applyRetention(at: Date = new Date(), env: NodeJS.ProcessEnv = process.env): Promise<RetentionResult> {
  const rawCutoff = new Date(at.getTime() - retentionDays(env) * MS_PER_DAY);
  const rollupCutoff = utcDay(new Date(at.getTime() - rollupRetentionDays(env) * MS_PER_DAY));
  const [a, w, s, l, u] = await Promise.all([
    prisma.activityEvent.deleteMany({ where: { ts: { lt: rawCutoff } } }),
    prisma.webVisit.deleteMany({ where: { ts: { lt: rawCutoff } } }),
    prisma.socialEvent.deleteMany({ where: { createdAt: { lt: rawCutoff } } }),
    prisma.locationPing.deleteMany({ where: { timestamp: { lt: rawCutoff } } }),
    prisma.appUsageDaily.deleteMany({ where: { day: { lt: rollupCutoff } } }),
  ]);
  return { activityEvents: a.count, webVisits: w.count, socialEvents: s.count, locationPings: l.count, usageDays: u.count };
}

/** Every child-scoped table, in an order that respects the foreign keys. Exported so a test can assert the list. */
export const CHILD_SCOPED_DELETE_ORDER = [
  "deviceCommand",
  "locationPing",
  "alert",
  "activityEvent",
  "socialEvent",
  "installRequest",
  "webVisit",
  "appUsageDaily",
  "device",
  "ruleSet",
  "geofence",
  "consentRecord",
  "child",
] as const;

export interface EraseResult {
  erased: true;
  childId: string;
  deletedDevices: string[];
  rows: Record<string, number>;
}

/**
 * GDPR erasure cascade (ADR-0013 §erasure): every child-scoped row in one transaction, then the
 * Redis state that belongs to the child and its devices. Each deleted device's token is revoked the
 * same way an unpair does (the key is security state — #56), so an erased child's agent cannot keep
 * posting with its 10-year JWT.
 */
export async function eraseChildData(childId: string, deviceTokenTtlSeconds: number): Promise<EraseResult> {
  const devices = await prisma.device.findMany({ where: { childId }, select: { id: true } });
  const deviceIds = devices.map((d) => d.id);
  const results = await prisma.$transaction([
    prisma.deviceCommand.deleteMany({ where: { deviceId: { in: deviceIds } } }),
    prisma.locationPing.deleteMany({ where: { childId } }),
    prisma.alert.deleteMany({ where: { childId } }),
    prisma.activityEvent.deleteMany({ where: { childId } }),
    prisma.socialEvent.deleteMany({ where: { childId } }),
    prisma.installRequest.deleteMany({ where: { childId } }),
    prisma.webVisit.deleteMany({ where: { childId } }),
    prisma.appUsageDaily.deleteMany({ where: { childId } }),
    prisma.device.deleteMany({ where: { childId } }),
    prisma.ruleSet.deleteMany({ where: { childId } }),
    prisma.geofence.deleteMany({ where: { childId } }),
    prisma.consentRecord.deleteMany({ where: { childId } }),
    prisma.child.delete({ where: { id: childId } }),
  ]);
  const rows: Record<string, number> = {};
  CHILD_SCOPED_DELETE_ORDER.forEach((name, i) => {
    const r = results[i] as { count?: number } | undefined;
    rows[name] = typeof r?.count === "number" ? r.count : 1;
  });

  const redis = getRedis();
  const nowIso = new Date().toISOString();
  for (const id of deviceIds) {
    await redis.set(`revoked:device:${id}`, nowIso, "EX", deviceTokenTtlSeconds).catch(() => {});
    await redis.del(`device:${id}:telemetry`, `device:${id}:command-queue`).catch(() => {});
  }
  // Today's and yesterday's usage cache (the key carries a 2-day TTL).
  const t = utcDay();
  const y = new Date(t.getTime() - MS_PER_DAY);
  await redis.del(`usage:child:${childId}:${dayKey(t)}`, `usage:child:${childId}:${dayKey(y)}`).catch(() => {});
  return { erased: true, childId, deletedDevices: deviceIds, rows };
}
