import { describe, expect, it } from "vitest";
import {
  RESTART_WARNING_GAP_MINUTES,
  SAME_BOOT_TOLERANCE_MS,
  bootClock,
  bootReportBody,
  decideBootReport,
} from "../src/lib/bootReport.js";

/**
 * Issue #867: a restart takes 1–2 minutes and the 30-minute silence window must stay as it is, so the gap is
 * reported by the device (`bootedAt`) and this module decides what the report means. Every row below is a
 * value the decision can get wrong in a way the parent would read as a fact.
 *
 * Mutants, one row each: compare `bootedAt` to `now` instead of to `lastSeen` → [the gap is the downtime];
 * treat a missing stored value as "same boot" → [the first report is a new boot]; use `>=` on the tolerance
 * → [a tick that moved the instant by 90 s is still the same boot]; drop the `lastSeen < bootedAt` guard →
 * [a boot older than the last report is not a negative gap]; use `>` for the warning floor → [a 30-minute gap
 * is a warning].
 */
describe("boot report (#867)", () => {
  const now = new Date("2026-11-17T10:02:00Z");
  const bootedAt = new Date("2026-11-17T10:00:00Z");
  const maxAheadMs = 5 * 60_000;

  const decide = (input: Partial<Parameters<typeof decideBootReport>[0]> = {}) =>
    decideBootReport({ bootedAt, storedBootAt: null, lastSeen: null, now, maxAheadMs, ...input });

  it("treats the first report of a boot instant as a new boot", () => {
    const report = decide({ lastSeen: new Date("2026-11-17T09:58:00Z") });
    expect(report).toMatchObject({ kind: "new_boot", gapMinutes: 2, severity: "info" });
  });

  it("measures the gap from the last report before the boot, not from the server's clock", () => {
    // Two minutes down, but the tick arrives four minutes after the boot (the agent was busy): the parent
    // must read the downtime, not the delay in reporting it.
    const report = decide({ lastSeen: new Date("2026-11-17T09:58:00Z"), now: new Date("2026-11-17T10:04:00Z") });
    expect(report).toMatchObject({ kind: "new_boot", gapMinutes: 2 });
  });

  it("does not alert again for a repeated tick of the same boot", () => {
    expect(decide({ storedBootAt: bootedAt })).toEqual({ kind: "same_boot" });
    // The agent recomputes `now - elapsedRealtime` every tick, so a few seconds of jitter is the same boot.
    expect(decide({ storedBootAt: new Date(bootedAt.getTime() + SAME_BOOT_TOLERANCE_MS) })).toEqual({ kind: "same_boot" });
    expect(decide({ storedBootAt: new Date(bootedAt.getTime() - SAME_BOOT_TOLERANCE_MS) })).toEqual({ kind: "same_boot" });
  });

  it("calls a moved instant beyond the tolerance a new boot", () => {
    const report = decide({ storedBootAt: new Date(bootedAt.getTime() - SAME_BOOT_TOLERANCE_MS - 1) });
    expect(report.kind).toBe("new_boot");
  });

  it("drops a boot instant from the future instead of storing it", () => {
    expect(decide({ bootedAt: new Date(now.getTime() + maxAheadMs + 1) })).toMatchObject({ kind: "clock_ahead" });
    // Exactly at the skew allowance is still a clock that can be right.
    expect(decide({ bootedAt: new Date(now.getTime() + maxAheadMs) }).kind).toBe("new_boot");
    expect(decide({ bootedAt: null })).toEqual({ kind: "none" });
  });

  it("reports a zero gap when there is no earlier lastSeen, or when it is not earlier", () => {
    expect(decide()).toMatchObject({ kind: "new_boot", gapMinutes: 0, severity: "info" });
    // A device clock behind the server's: the boot looks older than its own last report. There is no
    // measurable downtime, and a negative one must never reach the body.
    expect(decide({ lastSeen: new Date("2026-11-17T10:01:00Z") })).toMatchObject({ gapMinutes: 0 });
  });

  it("warns at exactly the silence window and only below it is info", () => {
    expect(RESTART_WARNING_GAP_MINUTES).toBe(30);
    const gapMinutes = (minutes: number) => decide({ lastSeen: new Date(bootedAt.getTime() - minutes * 60_000) });
    expect(gapMinutes(30)).toMatchObject({ gapMinutes: 30, severity: "warning" });
    expect(gapMinutes(29)).toMatchObject({ gapMinutes: 29, severity: "info" });
    // Rounds to whole minutes: 90 seconds down reads as 2 minutes, the wall clock a parent would say.
    expect(gapMinutes(1.5)).toMatchObject({ gapMinutes: 2 });
  });

  it("renders the restart in the family's clock and the gap in words", () => {
    const report = decide({ lastSeen: new Date("2026-11-17T09:58:00Z") });
    if (report.kind !== "new_boot") throw new Error("expected a new boot");
    // 10:00Z is 14:00 in Asia/Dubai (UTC+4), the family's clock the digest and "blocked now" also use.
    expect(bootClock(report.bootedAt, "Asia/Dubai")).toBe("14:00");
    expect(bootReportBody(report, "Pixel 7a", "Asia/Dubai")).toBe("Pixel 7a restarted at 14:00, back after 2 minutes.");
    expect(bootReportBody({ ...report, gapMinutes: 1 }, "Pixel 7a", "UTC")).toBe("Pixel 7a restarted at 10:00, back after 1 minute.");
    // Zero is not printed as "0 minutes": there is no downtime to claim.
    expect(bootReportBody({ ...report, gapMinutes: 0 }, "Pixel 7a", "UTC")).toBe("Pixel 7a restarted at 10:00.");
    // An unusable zone falls back to UTC rather than throwing inside the alert path.
    expect(bootClock(report.bootedAt, "Mars/Olympus")).toBe("10:00");
  });
});
