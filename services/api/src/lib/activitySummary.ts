import { prisma } from "../db.js";
import { hostOf, isExcludedSiteHost } from "./siteNames.js";
import { usageSeries, type UsageDay } from "./usageModel.js";

/** Public summary shape for GET /reports/summary (#4). */
export interface ActivitySummary {
  totalAppMinutes: number;
  topApps: Array<{ name: string; minutes: number }>;
  urlVisits: number;
  topBlockedDomains: Array<{ domain: string; count: number }>;
  socialConcerns: number;
  calls: number;
  sms: number;
}

/** Full aggregate including internal counters used by the wellbeing score. */
interface ActivityAggregate {
  totalAppMinutes: number;
  appMinutes: Map<string, number>;
  visitedHosts: Set<string>;
  blockedDomains: Map<string, number>;
  blockedHits: number;
  calls: number;
  sms: number;
}

export interface WellbeingScore {
  childId: string;
  week: string;
  score: number;
  breakdown: { usage: number; social: number; safety: number };
}

const TOP_LIMIT = 8;
const DEFAULT_DAILY_LIMIT_MINUTES = 180;
const MS_PER_DAY = 86_400_000;

function asRecord(payload: unknown): Record<string, unknown> {
  return payload && typeof payload === "object" ? (payload as Record<string, unknown>) : {};
}

/**
 * Pure JS aggregation over a window of ActivityEvents (spec: compute in JS, not SQL).
 *
 * `includeUnblockedUrls` is the site-name flag (ADR-0043's sibling decision, #830/#841): while it is off,
 * an unblocked `url` row is not browsing history anyone may see — not in the web report, not in the
 * activity report, and not counted into this summary either. Blocked attempts stay; they are the parent's
 * own rule reporting itself.
 */
function aggregateActivityEvents(
  events: Array<{ type: string; payload: unknown }>,
  includeUnblockedUrls = false,
): ActivityAggregate {
  const appMinutes = new Map<string, number>();
  const blockedDomains = new Map<string, number>();
  let totalAppMinutes = 0;
  // #841 UI/UX condition 3: the label says "sites visited", so the count is **distinct hosts**, not URL
  // events — ten visits to one site is one site. A blocked attempt is not a visit either: it has its own
  // counter (`blockedHits`, `topBlockedDomains`), so it does not enter this set.
  const visitedHosts = new Set<string>();
  let blockedHits = 0;
  let calls = 0;
  let sms = 0;
  for (const event of events) {
    const payload = asRecord(event.payload);
    if (event.type === "app_usage") {
      if (payload.live === true) continue;
      const minutes = typeof payload.minutes === "number" ? payload.minutes : 0;
      const app = typeof payload.app === "string" && payload.app ? payload.app : "unknown";
      totalAppMinutes += minutes;
      appMinutes.set(app, (appMinutes.get(app) ?? 0) + minutes);
    } else if (event.type === "url") {
      // Claude's ruling on #841 finding 5: with the flag off, no host is shown or counted — a blocked
      // attempt included. Its **count** still feeds the safety score (the parent's own rule reporting
      // itself), which is what "a count with no host is fine" allows.
      if (!includeUnblockedUrls) {
        if (payload.blocked === true) blockedHits += 1;
        continue;
      }
      const rawHost = typeof payload.domain === "string" && payload.domain
        ? payload.domain
        : typeof payload.url === "string" ? payload.url : "";
      const host = hostOf(rawHost) || (typeof payload.domain === "string" && payload.domain ? payload.domain.trim().toLowerCase() : "unknown");
      if (host !== "unknown" && isExcludedSiteHost(host)) continue;
      if (payload.blocked === true) {
        blockedHits += 1;
        blockedDomains.set(host, (blockedDomains.get(host) ?? 0) + 1);
      } else {
        visitedHosts.add(host);
      }
    } else if (event.type === "call") {
      calls += 1;
    } else if (event.type === "sms") {
      sms += 1;
    }
  }
  return {
    totalAppMinutes,
    appMinutes,
    visitedHosts,
    blockedDomains,
    blockedHits,
    calls,
    sms,
  };
}

/**
 * Aggregate a child's activity over the trailing `days` days (#4, #830 row 5).
 *
 * Device telemetry (`POST /v1/devices/:id/telemetry`) writes durable per-day totals and per-app minutes to
 * `AppUsageDaily` without writing `ActivityEvent` rows (and live heartbeats are skipped from `ActivityEvent`
 * on purpose), while persistent `POST /v1/devices/:id/activity` batches write both `ActivityEvent` and
 * `AppUsageDaily` / `WebVisit`. Reading `ActivityEvent` alone left `ReportsScreen` (`/v1/reports/summary`)
 * showing 9 min while `/v1/reports/usage` held 2,797 min on staging (19 Nov). Reconciling with `Math.max`
 * per resolved app label and per blocked host avoids double-counting batches that wrote both tables.
 */
export async function summarizeChildActivity(
  childId: string,
  days: number,
  options: { siteNames?: boolean } = {},
): Promise<ActivitySummary> {
  const now = new Date();
  const since = new Date(now.getTime() - days * MS_PER_DAY);
  const siteNames = options.siteNames === true;
  const [rawEvents, series, deviceApps, webRows, rawSocialConcerns] = await Promise.all([
    prisma.activityEvent.findMany({ where: { childId, ts: { gte: since } } }),
    usageSeries(childId, days, now),
    prisma.deviceApp.findMany({ where: { device: { childId } }, select: { packageId: true, label: true } }),
    siteNames
      ? prisma.webVisit.findMany({ where: { childId, ts: { gte: since } }, select: { domain: true, blocked: true } })
      : Promise.resolve([]),
    prisma.socialEvent.count({ where: { childId, createdAt: { gte: since } } }),
  ]);
  const events = rawEvents ?? [];
  const socialConcerns = rawSocialConcerns ?? 0;
  const aggregate = aggregateActivityEvents(events, siteNames);

  const labelByPackage = new Map<string, string>();
  for (const row of deviceApps ?? []) {
    if (typeof row?.packageId === "string" && row.packageId.trim() && typeof row?.label === "string" && row.label.trim()) {
      labelByPackage.set(row.packageId.trim(), row.label.trim());
    }
  }
  const displayNameOf = (raw: string) => labelByPackage.get(raw) ?? raw;

  const rollupTotal = series.reduce((sum: number, day: UsageDay) => sum + day.minutes, 0);
  const rollupApps = new Map<string, number>();
  for (const day of series) {
    for (const entry of day.apps) {
      const name = displayNameOf(entry.app);
      rollupApps.set(name, (rollupApps.get(name) ?? 0) + entry.minutes);
    }
  }
  const eventApps = new Map<string, number>();
  for (const [rawApp, minutes] of aggregate.appMinutes) {
    const name = displayNameOf(rawApp);
    eventApps.set(name, (eventApps.get(name) ?? 0) + minutes);
  }
  const mergedApps = new Map<string, number>();
  for (const name of new Set([...rollupApps.keys(), ...eventApps.keys()])) {
    const minutes = Math.max(rollupApps.get(name) ?? 0, eventApps.get(name) ?? 0);
    if (minutes > 0) mergedApps.set(name, minutes);
  }
  const mergedPerAppSum = [...mergedApps.values()].reduce((sum, m) => sum + m, 0);
  const totalAppMinutes = Math.max(rollupTotal, aggregate.totalAppMinutes, mergedPerAppSum);

  const visitedHosts = new Set<string>(aggregate.visitedHosts);
  const blockedDomains = new Map<string, number>(aggregate.blockedDomains);
  if (siteNames) {
    const webBlockedCounts = new Map<string, number>();
    for (const visit of webRows ?? []) {
      const host = hostOf(String(visit?.domain ?? ""));
      if (!host || host === "unknown" || isExcludedSiteHost(host)) continue;
      if (visit.blocked === true) {
        webBlockedCounts.set(host, (webBlockedCounts.get(host) ?? 0) + 1);
      } else {
        visitedHosts.add(host);
      }
    }
    for (const [host, count] of webBlockedCounts) {
      blockedDomains.set(host, Math.max(blockedDomains.get(host) ?? 0, count));
    }
  }

  const byValueDesc = (a: [string, number], b: [string, number]) => b[1] - a[1];
  return {
    totalAppMinutes,
    topApps: [...mergedApps.entries()].sort(byValueDesc).slice(0, TOP_LIMIT).map(([name, minutes]) => ({ name, minutes })),
    urlVisits: siteNames ? visitedHosts.size : 0,
    topBlockedDomains: siteNames
      ? [...blockedDomains.entries()].sort(byValueDesc).slice(0, TOP_LIMIT).map(([domain, count]) => ({ domain, count }))
      : [],
    socialConcerns,
    calls: aggregate.calls,
    sms: aggregate.sms,
  };
}

/** Current calendar week in ISO YYYY-Www form (used as the default wellbeing week label). */
export function currentIsoWeek(now = new Date()): string {
  const date = new Date(Date.UTC(now.getFullYear(), now.getMonth(), now.getDate()));
  const dayNum = date.getUTCDay() || 7;
  date.setUTCDate(date.getUTCDate() + 4 - dayNum);
  const yearStart = new Date(Date.UTC(date.getUTCFullYear(), 0, 1));
  const week = Math.ceil(((date.getTime() - yearStart.getTime()) / MS_PER_DAY + 1) / 7);
  return `${date.getUTCFullYear()}-W${String(week).padStart(2, "0")}`;
}

/**
 * Deterministic 0-100 wellbeing score (#28). NOTE: the formula is a documented
 * simplification — start at 100, then subtract usage overage (beyond 50% of the
 * child's daily limit across the window), social concerns, and blocked-site hits.
 */
export async function computeWellbeingScore(childId: string, week: string, days = 7): Promise<WellbeingScore> {
  const now = new Date();
  const since = new Date(now.getTime() - days * MS_PER_DAY);
  const [child, rawEvents, series, rawSocialConcerns] = await Promise.all([
    prisma.child.findUnique({ where: { id: childId }, include: { ruleSet: true } }),
    prisma.activityEvent.findMany({ where: { childId, ts: { gte: since } } }),
    usageSeries(childId, days, now),
    prisma.socialEvent.count({ where: { childId, createdAt: { gte: since } } }),
  ]);
  const dailyLimit = child?.ruleSet?.dailyLimitMinutes ?? DEFAULT_DAILY_LIMIT_MINUTES;
  const aggregate = aggregateActivityEvents(rawEvents ?? []);
  const rollupTotal = series.reduce((sum: number, day: UsageDay) => sum + day.minutes, 0);
  const effectiveMinutes = Math.max(rollupTotal, aggregate.totalAppMinutes);
  const socialConcerns = rawSocialConcerns ?? 0;
  // NOTE: usageRatio above 0.5 of the allowed budget starts costing points.
  const usageRatio = effectiveMinutes / (dailyLimit * days || 1);
  const usage = 30 * Math.max(0, usageRatio - 0.5) * 2;
  const social = 5 * socialConcerns;
  const safety = 3 * aggregate.blockedHits;
  const score = Math.max(0, Math.round(100 - usage - social - safety));
  return { childId, week, score, breakdown: { usage: Math.round(usage), social, safety } };
}
