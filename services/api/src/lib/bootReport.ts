/**
 * Issue #867: a child phone restart takes one to two minutes, and the server never saw it.
 *
 * The silence watch is deliberately 30 minutes (`SILENT_MIN_SAFE_MINUTES` in `jobs/deviceSilence.ts`): it
 * has to tolerate one missed 15-minute telemetry report, and a false `device_silent` critical alert is
 * worse than a late true one. So the restart gap cannot be detected by lowering that window — the device
 * has to report it. The agent sends two values on every telemetry tick:
 *
 * - `bootedAt`, `now - SystemClock.elapsedRealtime()`: a value that is stable for the life of one boot;
 * - `bootCount`, Android's `Settings.Global.BOOT_COUNT`: a counter the platform increments once per boot.
 *
 * **Why both, and which one decides (#884 review, Fable's blocker 2).** `elapsedRealtime()` is monotonic,
 * `currentTimeMillis()` is not: moving the phone's clock by more than the tolerance moves `bootedAt` with
 * no restart, so an instant-only rule lets a child fabricate one alert per telemetry tick. The counter
 * cannot be moved that way. So when a report carries `bootCount` and one is stored, **the counts decide**
 * and `bootedAt` is used only for the time in the sentence and the length of the gap. The instant
 * comparison remains as the fallback when either side has no count (an agent older than this field, or the
 * first report after an upgrade): that fallback keeps the clock-move weakness, bounded by the first report
 * the server sees from a count-carrying agent, after which the count decides.
 *
 * This module is the whole decision, pure, so the thresholds, the gap and every counter transition are
 * testable without Postgres, Redis or a clock.
 *
 * Follow-up, out of scope here: Android safe mode runs no third-party agent at all, so a phone booted into
 * safe mode sends no `bootedAt` until it leaves safe mode, and that boot is indistinguishable here from any
 * other silence.
 */

/** Two `bootedAt` values within this of each other are the same boot — the fallback rule only. */
export const SAME_BOOT_TOLERANCE_MS = 90_000;

/**
 * At this gap the parent would also have received `device_silent`, so the restart explains an alarm they
 * already got and the alert is a warning rather than an info line. Kept equal to the Android silence window
 * (`SILENT_MIN_SAFE_MINUTES = 30`); `device-silence.test.ts` fails if the two drift.
 */
export const RESTART_WARNING_GAP_MINUTES = 30;

export interface BootReportInput {
  /** The instant the device says it booted, or null when this tick carried none. */
  bootedAt: Date | null;
  /** The platform's boot counter, or null when this tick carried none. */
  bootCount: number | null;
  /** `Device.lastBootAt` as it was before this upload. */
  storedBootAt: Date | null | undefined;
  /** `Device.lastBootCount` as it was before this upload. */
  storedBootCount: number | null | undefined;
  /** `Device.lastSeen` as it was before this upload — the last moment the phone was known alive. */
  lastSeen: Date | null | undefined;
  /** The server's receipt time. The only clock the decision trusts. */
  now: Date;
  /** How far the device clock may run ahead of ours before its report is a caller bug (5 minutes). */
  maxAheadMs: number;
}

export type BootReport =
  | { kind: "none" }
  /** Rejected as a caller bug: not stored, not alerted, upload still accepted. */
  | { kind: "clock_ahead"; bootedAt: Date }
  /**
   * There is no earlier boot to compare against — nothing stored yet, or the counter went backwards
   * (a factory reset or a restored image). The instant is stored and **no alert is raised**: the server
   * cannot know a restart happened, and an alert here would tell a parent about a boot it cannot date
   * (#884 review, blocker 1).
   */
  | { kind: "first_report"; bootedAt: Date; bootCount: number | null; reason: "no_previous" | "count_reset" }
  | { kind: "same_boot" }
  /**
   * The same boot, but this report is the first to carry a counter where the stored row has none — an agent
   * that was upgraded in place. Nothing is announced; the counter is recorded so that the *next* restart is
   * decided by the counter instead of by the instant.
   *
   * Reviewed on #884 (Fable): without this, a count-less row waits for the next restart to learn a count, so
   * the clock-move weakness of the instant fallback survives for up to a full uptime. Adopting it here
   * shortens that to one tick.
   */
  | { kind: "same_boot_adopt_count"; bootCount: number }
  | {
      kind: "new_boot";
      bootedAt: Date;
      bootCount: number | null;
      /** Minutes between the last known sign of life and the boot; 0 when there is nothing to compare. */
      gapMinutes: number;
      severity: "info" | "warning";
      previousLastSeen: Date | null;
    };

/**
 * What this tick means. The rule, in order:
 *
 * 1. No `bootedAt` → nothing (an older agent keeps working untouched).
 * 2. `bootedAt` more than `maxAheadMs` in the future → `clock_ahead`: a broken device clock is a caller bug,
 *    dropped the way an impossible activity timestamp is (`ACTIVITY_CLOCK_SKEW_MS` in routes/devices.ts).
 *    Nothing is stored, so the next tick with a sane instant still sees the count difference and reports.
 * 3. Both this report and the stored row carry a `bootCount` → **the counts decide**: equal is the same
 *    boot (the stored instant is left alone even if a moved clock makes it look different), a higher
 *    count is a new boot, and a **lower** count is `first_report`/`count_reset` — the device is reporting
 *    from an earlier state (wiped, restored, or a different build's counter), which is not a restart of the
 *    phone the parent knows about and must not read as tampering.
 * 4. Otherwise (a count on one side only) → the stored instant decides: nothing stored is `first_report`,
 *    within [SAME_BOOT_TOLERANCE_MS] is `same_boot_adopt_count` when this report carries a count and the
 *    stored row has none (so the next decision is count-led), otherwise the same boot; anything else is a
 *    new boot.
 *
 * The gap is measured against the previous `lastSeen`, not against `now`: `lastSeen` is the last report the
 * phone managed before it went down, so the number is the downtime, and a telemetry upload that arrives
 * long after boot does not inflate it.
 */
export function decideBootReport(input: BootReportInput): BootReport {
  const { bootedAt, bootCount, storedBootAt, storedBootCount, lastSeen, now, maxAheadMs } = input;
  if (!bootedAt) return { kind: "none" };
  if (bootedAt.getTime() - now.getTime() > maxAheadMs) return { kind: "clock_ahead", bootedAt };

  if (bootCount !== null && storedBootCount !== null && storedBootCount !== undefined) {
    // Equal counts mean the same boot, whatever the instant says: a moved wall clock is not a restart.
    if (bootCount === storedBootCount) return { kind: "same_boot" };
    if (bootCount < storedBootCount) {
      return { kind: "first_report", bootedAt, bootCount, reason: "count_reset" };
    }
    return newBoot(bootedAt, bootCount, lastSeen);
  }

  if (!storedBootAt) return { kind: "first_report", bootedAt, bootCount, reason: "no_previous" };
  if (Math.abs(bootedAt.getTime() - storedBootAt.getTime()) <= SAME_BOOT_TOLERANCE_MS) {
    // Same boot by the instant, and this report brings a counter the stored row does not have: record it so
    // the next restart is decided by the counter rather than by the clock (see `same_boot_adopt_count`).
    if (bootCount !== null && (storedBootCount === null || storedBootCount === undefined)) {
      return { kind: "same_boot_adopt_count", bootCount };
    }
    return { kind: "same_boot" };
  }
  return newBoot(bootedAt, bootCount, lastSeen);
}

function newBoot(bootedAt: Date, bootCount: number | null, lastSeen: Date | null | undefined): Extract<BootReport, { kind: "new_boot" }> {
  const previousLastSeen = lastSeen ?? null;
  // Only a `lastSeen` strictly before the boot is a gap. A phone whose clock is behind, or whose previous
  // report came from the same second as the boot, has no measurable downtime — 0, never a negative number.
  // Floor whole elapsed minutes so <60s stays "in less than a minute" (`gapMinutes=0`) and 29m45s stays `info`
  // until full 30m reaches `warning` (#889 Bureau thresholds).
  const gapMinutes =
    previousLastSeen && previousLastSeen.getTime() < bootedAt.getTime()
      ? Math.floor((bootedAt.getTime() - previousLastSeen.getTime()) / 60_000)
      : 0;
  return {
    kind: "new_boot",
    bootedAt,
    bootCount,
    gapMinutes,
    severity: gapMinutes >= RESTART_WARNING_GAP_MINUTES ? "warning" : "info",
    previousLastSeen,
  };
}

/**
 * The restart in the family's own clock, `14:32`.
 *
 * The alert body is stored as English and read verbatim by the parent app, so the time has to be rendered
 * here. A family has one zone (`Family.timezone`, ADR-0017/ADR-0020) and that is the clock its digests and
 * "blocked now" sentences already use; an unknown zone falls back to UTC rather than throwing inside the
 * alert path.
 */
/** Short month names matching Dart `DateFormat('d MMM', 'en')` regardless of host ICU data. */
const EN_SHORT_MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"] as const;

interface ZonedCalendarParts {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  clock: string;
}

/**
 * Extracts wall-clock calendar date and 24-hour `HH:mm` in the family's timezone, falling back to
 * UTC when a stored zone string is unknown (#884, #889).
 */
function zonedCalendarParts(date: Date, timeZone: string): ZonedCalendarParts {
  const extract = (zone: string): ZonedCalendarParts => {
    const parts = new Intl.DateTimeFormat("en-GB", {
      timeZone: zone,
      year: "numeric",
      month: "numeric",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
    }).formatToParts(date);
    const num = (type: Intl.DateTimeFormatPartTypes) => Number(parts.find((p) => p.type === type)?.value ?? 0);
    const pad = (n: number) => String(n).padStart(2, "0");
    const hour = num("hour");
    const minute = num("minute");
    return {
      year: num("year"),
      month: num("month"),
      day: num("day"),
      hour,
      minute,
      clock: `${pad(hour)}:${pad(minute)}`,
    };
  };
  try {
    return extract(timeZone);
  } catch {
    return extract("UTC");
  }
}

/**
 * Computes the family timezone's UTC offset in minutes at [date] (falling back to 0 / UTC for unknown zones).
 * Passed alongside `timeZone` in `bodyParams` so mobile clients without full IANA tables render exact family clocks (#889).
 */
export function zonedUtcOffsetMinutes(date: Date, timeZone: string): number {
  const parts = zonedCalendarParts(date, timeZone);
  const wallMs = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute);
  const utcMinuteMs = Date.UTC(
    date.getUTCFullYear(),
    date.getUTCMonth(),
    date.getUTCDate(),
    date.getUTCHours(),
    date.getUTCMinutes(),
  );
  return Math.round((wallMs - utcMinuteMs) / 60_000);
}

export function bootClock(bootedAt: Date, timeZone: string): string {
  return zonedCalendarParts(bootedAt, timeZone).clock;
}

function sameCalendarDay(a: { year: number; month: number; day: number }, b: { year: number; month: number; day: number }): boolean {
  return a.year === b.year && a.month === b.month && a.day === b.day;
}

/**
 * English fallback sentence mirroring the localized parent-app rules (#889):
 * - Today in the family's zone: `restarted at HH:MM`; yesterday: `restarted yesterday at HH:MM`;
 *   earlier: `restarted on 16 Nov at HH:MM` (with year when it differs from `now`'s year).
 * - Gaps `< 1` min say `in less than a minute`; `1..119` min stay minutes; `>= 120` min round to the
 *   nearest hour (`30m+` rounds up) with `about`.
 */
export function bootReportBody(
  report: Extract<BootReport, { kind: "new_boot" }>,
  model: string,
  timeZone: string,
  now: Date = new Date(),
): string {
  const bootParts = zonedCalendarParts(report.bootedAt, timeZone);
  const nowParts = zonedCalendarParts(now, timeZone);
  const yesterdayUtc = new Date(Date.UTC(nowParts.year, nowParts.month - 1, nowParts.day - 1));
  const yesterdayParts = {
    year: yesterdayUtc.getUTCFullYear(),
    month: yesterdayUtc.getUTCMonth() + 1,
    day: yesterdayUtc.getUTCDate(),
  };

  let when: string;
  if (sameCalendarDay(bootParts, nowParts)) {
    when = `at ${bootParts.clock}`;
  } else if (sameCalendarDay(bootParts, yesterdayParts)) {
    when = `yesterday at ${bootParts.clock}`;
  } else {
    const monthName = EN_SHORT_MONTHS[bootParts.month - 1] ?? "Jan";
    const dateLabel = bootParts.year === nowParts.year
      ? `${bootParts.day} ${monthName}`
      : `${bootParts.day} ${monthName} ${bootParts.year}`;
    when = `on ${dateLabel} at ${bootParts.clock}`;
  }

  let gapClause: string;
  if (report.gapMinutes <= 0) {
    gapClause = "in less than a minute";
  } else if (report.gapMinutes === 1) {
    gapClause = "after 1 minute";
  } else if (report.gapMinutes < 120) {
    gapClause = `after ${report.gapMinutes} minutes`;
  } else {
    const hours = Math.floor((report.gapMinutes + 30) / 60);
    gapClause = `after about ${hours} ${hours === 1 ? "hour" : "hours"}`;
  }
  return `${model} restarted ${when} and was back ${gapClause}.`;
}
