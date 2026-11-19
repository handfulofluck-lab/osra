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
 * reported by the device (`bootedAt`, and `bootCount` since #884) and this module decides what the report
 * means. Every row below is a value the decision can get wrong in a way the parent would read as a fact.
 *
 * Mutants, one row each: alert on a first report → [the first report is a baseline]; let a moved instant
 * decide when counts are present → [the clock, not the phone, moved]; treat a lower count as a restart →
 * [a reset count is a baseline]; require a count instead of falling back → [a count-less agent is still
 * compared by instant]; compare `bootedAt` to `now` instead of to `lastSeen` → [the gap is the downtime];
 * use `>=` on the tolerance → [a tick that moved the instant by 90 s is still the same boot]; drop the
 * `lastSeen < bootedAt` guard → [a boot older than the last report is not a negative gap].
 */
describe("boot report (#867)", () => {
  const now = new Date("2026-11-17T10:02:00Z");
  const bootedAt = new Date("2026-11-17T10:00:00Z");
  // A stored boot from an earlier day, so a default call is a `new_boot` and each row overrides only the
  // field it is about.
  const storedBootAt = new Date("2026-11-01T08:00:00Z");
  const maxAheadMs = 5 * 60_000;

  const decide = (input: Partial<Parameters<typeof decideBootReport>[0]> = {}) =>
    decideBootReport({ bootedAt, bootCount: null, storedBootAt, storedBootCount: null, lastSeen: null, now, maxAheadMs, ...input });

  it("stores the first report of a boot instant and raises nothing", () => {
    // Blocker 1 of #884: nothing is stored, so the server cannot know a restart happened. Storing the
    // baseline is the only honest result; an alert here would describe a boot days old as if it were news.
    expect(decide({ storedBootAt: null, lastSeen: new Date("2026-11-17T09:58:00Z") })).toEqual({
      kind: "first_report",
      bootedAt,
      bootCount: null,
      reason: "no_previous",
    });
  });

  it("keeps the first report after a phone is paired, even with a count", () => {
    expect(decide({ storedBootAt: null, storedBootCount: null, bootCount: 7 })).toMatchObject({
      kind: "first_report",
      reason: "no_previous",
      bootCount: 7,
    });
  });

  it("calls a higher boot count a restart, and the instant only dates it", () => {
    // The reported instant is an hour earlier than the stored one (a clock moved back) and the count moved
    // up by one: the phone restarted, and the alert must still exist with a zero gap rather than a negative.
    const report = decide({
      bootedAt: new Date(storedBootAt.getTime() - 3600_000),
      bootCount: 8,
      storedBootCount: 7,
      lastSeen: new Date("2026-11-01T07:58:00Z"),
    });
    expect(report).toMatchObject({ kind: "new_boot", gapMinutes: 0, severity: "info", bootCount: 8 });
  });

  it("ignores a moved instant when the count says the phone did not restart", () => {
    // Blocker 2 of #884: `bootedAt` is derived from a wall clock a child can set. Same count plus an hour
    // of drift is a clock move, not a reboot, and no alert (and no stored instant) may come of it.
    expect(
      decide({ bootedAt: new Date(storedBootAt.getTime() + 3600_000), bootCount: 7, storedBootCount: 7 }),
    ).toEqual({ kind: "same_boot" });
  });

  it("treats a lower count as a new baseline, not a restart of this phone", () => {
    // A factory reset or a restored image reports an earlier state. That is not tampering, and a parent
    // must not be told their phone restarted; it becomes the new baseline to compare against.
    expect(decide({ bootCount: 3, storedBootCount: 7 })).toEqual({
      kind: "first_report",
      bootedAt,
      bootCount: 3,
      reason: "count_reset",
    });
  });

  it("falls back to the instant when either side has no count, and records the first count it sees", () => {
    // An agent that ships the count after this server change: one report still compared by instant, which
    // is the fallback the code comment says keeps the clock-move weakness — bounded here, because the
    // returned baseline stores the count and every later report is decided by it.
    const viaUpgrade = decide({ bootCount: 7, storedBootCount: null, storedBootAt });
    expect(viaUpgrade).toMatchObject({ kind: "new_boot", bootCount: 7 });
    // A downgrade (or a report that omits the count): the stored count is ignored and the instant decides.
    expect(decide({ bootCount: null, storedBootCount: 7, storedBootAt }).kind).toBe("new_boot");
    // ...and within the tolerance it is still the same boot on that fallback.
    expect(
      decide({ bootCount: null, storedBootCount: 7, storedBootAt: new Date(bootedAt.getTime() - SAME_BOOT_TOLERANCE_MS) }).kind,
    ).toBe("same_boot");
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

  it("adopts a counter on a same-boot tick, and stops offering once it is stored", () => {
    // Fable's review of #884: a row with an instant and no counter is an agent upgraded in place. The tick
    // that first carries a counter records it, so the next restart is decided by the counter and not by a
    // clock the child can move. Mutant: return `same_boot` here and the weakness survives a full uptime.
    expect(decide({ storedBootAt: bootedAt, storedBootCount: null, bootCount: 7 })).toEqual({
      kind: "same_boot_adopt_count",
      bootCount: 7,
    });
    // Once stored, the same report is an ordinary same boot — no write, nothing to adopt.
    expect(decide({ storedBootAt: bootedAt, storedBootCount: 7, bootCount: 7 })).toEqual({ kind: "same_boot" });
    // A report that carries no counter has nothing to adopt either.
    expect(decide({ storedBootAt: bootedAt, storedBootCount: null, bootCount: null })).toEqual({ kind: "same_boot" });
    // A different counter on that path is a restart, not an adoption.
    expect(decide({ storedBootAt: bootedAt, storedBootCount: 6, bootCount: 7 }).kind).toBe("new_boot");
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

  it("renders the restart in the family's clock with today/yesterday/date and gap rounding (#867, #889)", () => {
    const report = decide({ lastSeen: new Date("2026-11-17T09:58:00Z") });
    if (report.kind !== "new_boot") throw new Error("expected a new boot");
    // 10:00Z is 14:00 in Asia/Dubai (UTC+4), the family's clock the digest and "blocked now" also use.
    expect(bootClock(report.bootedAt, "Asia/Dubai")).toBe("14:00");
    expect(bootReportBody(report, "Pixel 7a", "Asia/Dubai", now)).toBe(
      "Pixel 7a restarted at 14:00 and was back after 2 minutes.",
    );
    expect(bootReportBody({ ...report, gapMinutes: 1 }, "Pixel 7a", "UTC", now)).toBe(
      "Pixel 7a restarted at 10:00 and was back after 1 minute.",
    );
    // Zero gap uses "in less than a minute", never "0 minutes" (#889 Bureau rule).
    expect(bootReportBody({ ...report, gapMinutes: 0 }, "Pixel 7a", "UTC", now)).toBe(
      "Pixel 7a restarted at 10:00 and was back in less than a minute.",
    );
    // Yesterday vs older date (same year omits year; prior year includes year).
    const nextDay = new Date("2026-11-18T08:00:00Z");
    expect(bootReportBody({ ...report, gapMinutes: 119 }, "Pixel 7a", "UTC", nextDay)).toBe(
      "Pixel 7a restarted yesterday at 10:00 and was back after 119 minutes.",
    );
    expect(bootReportBody({ ...report, gapMinutes: 120 }, "Pixel 7a", "UTC", new Date("2026-11-20T08:00:00Z"))).toBe(
      "Pixel 7a restarted on 17 Nov at 10:00 and was back after about 2 hours.",
    );
    expect(bootReportBody({ ...report, gapMinutes: 149 }, "Pixel 7a", "UTC", new Date("2027-01-02T08:00:00Z"))).toBe(
      "Pixel 7a restarted on 17 Nov 2026 at 10:00 and was back after about 2 hours.",
    );
    // >= 120 minutes rounds to the nearest hour (30m+ rounds up).
    expect(bootReportBody({ ...report, gapMinutes: 150 }, "Pixel 7a", "UTC", now)).toBe(
      "Pixel 7a restarted at 10:00 and was back after about 3 hours.",
    );
    expect(bootReportBody({ ...report, gapMinutes: 600 }, "Pixel 7a", "UTC", now)).toBe(
      "Pixel 7a restarted at 10:00 and was back after about 10 hours.",
    );
    // An unusable zone falls back to UTC rather than throwing inside the alert path.
    expect(bootClock(report.bootedAt, "Mars/Olympus")).toBe("10:00");
  });
});
