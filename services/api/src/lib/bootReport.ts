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
 *    within [SAME_BOOT_TOLERANCE_MS] is the same boot, anything else is a new boot.
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
  if (Math.abs(bootedAt.getTime() - storedBootAt.getTime()) <= SAME_BOOT_TOLERANCE_MS) return { kind: "same_boot" };
  return newBoot(bootedAt, bootCount, lastSeen);
}

function newBoot(bootedAt: Date, bootCount: number | null, lastSeen: Date | null | undefined): Extract<BootReport, { kind: "new_boot" }> {
  const previousLastSeen = lastSeen ?? null;
  // Only a `lastSeen` strictly before the boot is a gap. A phone whose clock is behind, or whose previous
  // report came from the same second as the boot, has no measurable downtime — 0, never a negative number.
  const gapMinutes =
    previousLastSeen && previousLastSeen.getTime() < bootedAt.getTime()
      ? Math.round((bootedAt.getTime() - previousLastSeen.getTime()) / 60_000)
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
export function bootClock(bootedAt: Date, timeZone: string): string {
  const format = (zone: string) =>
    new Intl.DateTimeFormat("en-GB", { timeZone: zone, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(bootedAt);
  try {
    return format(timeZone);
  } catch {
    return format("UTC");
  }
}

/**
 * The sentence the parent reads, mirroring the silence alert's shape: the phone's model first, then what
 * happened. A zero gap is left out instead of printed as "0 minutes" — there is no downtime to report, and
 * a made-up number is the one thing a parent will act on.
 */
export function bootReportBody(report: Extract<BootReport, { kind: "new_boot" }>, model: string, timeZone: string): string {
  const at = `restarted at ${bootClock(report.bootedAt, timeZone)}`;
  if (report.gapMinutes <= 0) return `${model} ${at}.`;
  const unit = report.gapMinutes === 1 ? "minute" : "minutes";
  return `${model} ${at}, back after ${report.gapMinutes} ${unit}.`;
}
