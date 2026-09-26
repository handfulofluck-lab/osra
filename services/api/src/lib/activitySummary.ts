import { prisma } from "../db.js";

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
  topApps: Array<{ name: string; minutes: number }>;
  urlVisits: number;
  topBlockedDomains: Array<{ domain: string; count: number }>;
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

/** Pure JS aggregation over a window of ActivityEvents (spec: compute in JS, not SQL). */
function aggregateActivityEvents(events: Array<{ type: string; payload: unknown }>): ActivityAggregate {
  const appMinutes = new Map<string, number>();
  const blockedDomains = new Map<string, number>();
  let totalAppMinutes = 0;
  let urlVisits = 0;
  let blockedHits = 0;
  let calls = 0;
  let sms = 0;
  for (const event of events) {
    const payload = asRecord(event.payload);
    if (event.type === "app_usage") {
      const minutes = typeof payload.minutes === "number" ? payload.minutes : 0;
      const app = typeof payload.app === "string" && payload.app ? payload.app : "unknown";
      totalAppMinutes += minutes;
      appMinutes.set(app, (appMinutes.get(app) ?? 0) + minutes);
    } else if (event.type === "url") {
      urlVisits += 1;
      if (payload.blocked === true) {
        blockedHits += 1;
        const domain = typeof payload.domain === "string" && payload.domain ? payload.domain : "unknown";
        blockedDomains.set(domain, (blockedDomains.get(domain) ?? 0) + 1);
      }
    } else if (event.type === "call") {
      calls += 1;
    } else if (event.type === "sms") {
      sms += 1;
    }
  }
  const byValueDesc = (a: [string, number], b: [string, number]) => b[1] - a[1];
  return {
    totalAppMinutes,
    topApps: [...appMinutes.entries()].sort(byValueDesc).slice(0, TOP_LIMIT).map(([name, minutes]) => ({ name, minutes })),
    urlVisits,
    topBlockedDomains: [...blockedDomains.entries()].sort(byValueDesc).slice(0, TOP_LIMIT).map(([domain, count]) => ({ domain, count })),
    blockedHits,
    calls,
    sms,
  };
}

/** Aggregate a child's ActivityEvents over the trailing `days` days (#4). */
export async function summarizeChildActivity(childId: string, days: number): Promise<ActivitySummary> {
  const since = new Date(Date.now() - days * MS_PER_DAY);
  const events = await prisma.activityEvent.findMany({ where: { childId, ts: { gte: since } } });
  const aggregate = aggregateActivityEvents(events);
  const socialConcerns = await prisma.socialEvent.count({ where: { childId, createdAt: { gte: since } } });
  const { blockedHits: _blockedHits, ...summary } = aggregate;
  return { ...summary, socialConcerns };
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
  const child = await prisma.child.findUnique({ where: { id: childId }, include: { ruleSet: true } });
  const dailyLimit = child?.ruleSet?.dailyLimitMinutes ?? DEFAULT_DAILY_LIMIT_MINUTES;
  const since = new Date(Date.now() - days * MS_PER_DAY);
  const events = await prisma.activityEvent.findMany({ where: { childId, ts: { gte: since } } });
  const aggregate = aggregateActivityEvents(events);
  const socialConcerns = await prisma.socialEvent.count({ where: { childId, createdAt: { gte: since } } });
  // NOTE: usageRatio above 0.5 of the allowed budget starts costing points.
  const usageRatio = aggregate.totalAppMinutes / (dailyLimit * days || 1);
  const usage = 30 * Math.max(0, usageRatio - 0.5) * 2;
  const social = 5 * socialConcerns;
  const safety = 3 * aggregate.blockedHits;
  const score = Math.max(0, Math.round(100 - usage - social - safety));
  return { childId, week, score, breakdown: { usage: Math.round(usage), social, safety } };
}
