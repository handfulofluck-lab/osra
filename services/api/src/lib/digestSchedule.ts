/**
 * ADR-0017: the weekly and daily digests are due at the **family's local hour**, not a fixed UTC hour.
 *
 * This module is pure on purpose: the scheduler's only decisions that can silently send twice (or not
 * at all) are "what is the family's local day/hour/week right now" and "has this period already been
 * sent", so they are computed from a `Date` and an IANA zone and unit-tested without Postgres, Redis
 * or a clock. `digestScheduler.ts` owns the I/O.
 *
 * The selection rule from the ADR is "at or past the hour", not equality: a DST spring-forward that
 * skips the configured hour then sends at the next hour instead of skipping the day, and the period key
 * (local date / ISO week) makes a repeated fall-back hour idempotent.
 */

export type DigestKind = "daily" | "weekly";

export interface LocalParts {
  /** Local calendar date, `YYYY-MM-DD`. */
  date: string;
  hour: number;
  /** ISO weekday: 1 = Monday … 7 = Sunday. */
  weekday: number;
  /** ISO week key, `YYYY-Www` (the week that contains the local Thursday). */
  isoWeek: string;
}

const FORMATTER_CACHE = new Map<string, Intl.DateTimeFormat>();

function formatter(timeZone: string): Intl.DateTimeFormat {
  const cached = FORMATTER_CACHE.get(timeZone);
  if (cached) return cached;
  const f = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
    weekday: "short",
  });
  FORMATTER_CACHE.set(timeZone, f);
  return f;
}

/** True when `timeZone` is an IANA name this runtime knows (the write path validates with this). */
export function isValidTimeZone(timeZone: string): boolean {
  try {
    new Intl.DateTimeFormat("en-CA", { timeZone });
    return true;
  } catch {
    return false;
  }
}

/**
 * #476: the zone's offset from UTC at `now`, in whole minutes (Asia/Dubai → 240, America/New_York in
 * winter → -300). The parent app shifts its clock by this instead of shipping a tz database, so the
 * "Blocked now by …" sentence is computed in the family's zone, where the child's phone enforces it.
 */
export function utcOffsetMinutes(now: Date, timeZone: string): number {
  const parts = formatter(timeZone).formatToParts(now);
  const get = (type: string): number => Number(parts.find((p) => p.type === type)?.value ?? "0");
  const asUtc = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"), get("second"));
  const wholeSeconds = Math.floor(now.getTime() / 1000) * 1000;
  return Math.round((asUtc - wholeSeconds) / 60_000);
}

const WEEKDAY_NUMBER: Record<string, number> = {
  Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7,
};

/** Local calendar fields for `now` in `timeZone`. */
export function localParts(now: Date, timeZone: string): LocalParts {
  const parts = formatter(timeZone).formatToParts(now);
  const get = (type: string): string => parts.find((p) => p.type === type)?.value ?? "";
  const year = get("year");
  const month = get("month");
  const day = get("day");
  const hour = Number(get("hour"));
  const weekday = WEEKDAY_NUMBER[get("weekday")] ?? 1;
  const date = `${year}-${month}-${day}`;
  return { date, hour, weekday, isoWeek: isoWeekKey(year, month, day) };
}

/**
 * ISO-8601 week key for a local calendar date. The week belongs to the year that contains its
 * Thursday, which is what makes late-December dates map to `W01` of the next year.
 */
export function isoWeekKey(year: string, month: string, day: string): string {
  const d = new Date(Date.UTC(Number(year), Number(month) - 1, Number(day)));
  const dayNum = d.getUTCDay() || 7; // Sunday = 7
  d.setUTCDate(d.getUTCDate() + 4 - dayNum); // move to the Thursday of this week
  const isoYear = d.getUTCFullYear();
  const yearStart = Date.UTC(isoYear, 0, 1);
  const week = Math.ceil(((d.getTime() - yearStart) / 86_400_000 + 1) / 7);
  return `${isoYear}-W${String(week).padStart(2, "0")}`;
}

/** The idempotency key for a (family, kind) send: local date for daily, ISO week for weekly. */
export function digestPeriod(kind: DigestKind, parts: LocalParts): string {
  return kind === "daily" ? parts.date : parts.isoWeek;
}

/**
 * Which digests are due for one family at `now`. The caller is responsible for filtering out periods
 * that were already sent (`digestPeriod` is the key it stores).
 *
 * - outside the local send hour (before `digestHour`): nothing;
 * - weekly: only when the local day is Sunday;
 * - daily: every local day.
 */
export function digestsDueAt(now: Date, timeZone: string, digestHour: number): DigestKind[] {
  const parts = localParts(now, timeZone);
  if (parts.hour < digestHour) return [];
  return parts.weekday === 7 ? ["daily", "weekly"] : ["daily"];
}

/**
 * The env hour, clamped: `DIGEST_HOUR` is a **local** hour (ADR-0017), default 18.
 *
 * `DIGEST_HOUR_UTC` is the pre-ADR-0017 name and is still read as a fallback, but as a **local** hour
 * too — nothing here converts it, because ADR-0017 made the hour local for every family and the name
 * is now wrong (F3 of the #93 review). `startDigestScheduler` warns once at boot when it is the one
 * set, so an operator still on the old name learns the meaning changed; rename it in a deployment.
 */
export function digestHour(env: NodeJS.ProcessEnv = process.env): number {
  const raw = Number(env.DIGEST_HOUR ?? env.DIGEST_HOUR_UTC ?? 18);
  return Number.isInteger(raw) && raw >= 0 && raw <= 23 ? raw : 18;
}
