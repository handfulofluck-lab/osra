/**
 * Issue #867: a child phone restart takes one to two minutes, and the server never saw it.
 *
 * The silence watch is deliberately 30 minutes (`SILENT_MIN_SAFE_MINUTES` in `jobs/deviceSilence.ts`): it
 * has to tolerate one missed 15-minute telemetry report, and a false `device_silent` critical alert is
 * worse than a late true one. So the restart gap cannot be detected by lowering that window — the device
 * has to report it. The agent sends `bootedAt` on every telemetry tick, computed as
 * `now - SystemClock.elapsedRealtime()`: a value that is stable for the life of one boot and changes only
 * when the phone restarts. Comparing it with the stored one is therefore a restart detector with no clock
 * arithmetic of ours in it.
 *
 * The whole decision is this module, pure, so the thresholds and every gap they produce are testable
 * without Postgres, Redis or a clock.
 *
 * Follow-up, out of scope here: Android safe mode runs no third-party agent at all, so a phone booted into
 * safe mode sends no `bootedAt` until it leaves safe mode, and that boot is indistinguishable here from any
 * other silence.
 */

/** Two `bootedAt` values within this of each other are the same boot. */
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
  /** `Device.lastBootAt` as it was before this upload. */
  storedBootAt: Date | null | undefined;
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
  | { kind: "same_boot" }
  | {
      kind: "new_boot";
      bootedAt: Date;
      /** Minutes between the last known sign of life and the boot; 0 when there is nothing to compare. */
      gapMinutes: number;
      severity: "info" | "warning";
      previousLastSeen: Date | null;
    };

/**
 * What this tick means. A report is a **new boot** when nothing is stored yet, or when the instant moved by
 * more than [SAME_BOOT_TOLERANCE_MS] — a real restart moves it by the phone's uptime, which is minutes to
 * days, while `elapsedRealtime()` across two telemetry ticks of one boot does not move at all.
 *
 * The gap is measured against the previous `lastSeen`, not against `now`: `lastSeen` is the last report the
 * phone managed before it went down, so the number is the downtime, and a telemetry upload that arrives
 * long after boot does not inflate it.
 */
export function decideBootReport(input: BootReportInput): BootReport {
  const { bootedAt, storedBootAt, lastSeen, now, maxAheadMs } = input;
  if (!bootedAt) return { kind: "none" };
  // A future boot instant is a broken device clock, not news: drop the field the way an impossible
  // activity timestamp is dropped (`ACTIVITY_CLOCK_SKEW_MS` in routes/devices.ts), and keep the upload.
  if (bootedAt.getTime() - now.getTime() > maxAheadMs) return { kind: "clock_ahead", bootedAt };
  if (storedBootAt && Math.abs(bootedAt.getTime() - storedBootAt.getTime()) <= SAME_BOOT_TOLERANCE_MS) {
    return { kind: "same_boot" };
  }
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
