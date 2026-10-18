import { describe, expect, it, vi } from "vitest";
import {
  digestHour,
  digestPeriod,
  digestsDueAt,
  isoWeekKey,
  isValidTimeZone,
  localParts,
} from "../src/lib/digestSchedule.js";
import { startDigestScheduler, stopDigestScheduler } from "../src/jobs/digestScheduler.js";

/**
 * ADR-0017 acceptance, expressed as local-clock cases. The scheduler's dangerous failures are silent:
 * sending a Dubai family its "evening" digest at 22:00, sending twice across a DST fall-back hour, or
 * skipping a day because a spring-forward deleted the configured hour.
 */
describe("local clock", () => {
  const t = new Date("2026-10-18T14:00:00Z"); // Sunday 14:00 UTC

  it("reads the family's local calendar fields, not the server's", () => {
    const dubai = localParts(t, "Asia/Dubai");
    expect(dubai.date).toBe("2026-10-18");
    expect(dubai.hour).toBe(18);
    expect(dubai.weekday).toBe(7); // Sunday

    const utc = localParts(t, "UTC");
    expect(utc.hour).toBe(14);
  });

  it("a Sunday in +14 and a Saturday in -11 at the same instant", () => {
    const noon = new Date("2026-10-17T12:00:00Z");
    expect(localParts(noon, "Pacific/Kiritimati").weekday).toBe(7);
    expect(localParts(noon, "Pacific/Pago_Pago").weekday).toBe(6);
  });

  it("rejects a zone the runtime does not know", () => {
    expect(isValidTimeZone("Asia/Dubai")).toBe(true);
    expect(isValidTimeZone("Mars/Olympus_Mons")).toBe(false);
  });
});

describe("which digests are due (ADR-0017 acceptance)", () => {
  it("14:00Z Sunday: Dubai sends at 18:00 local, UTC has not reached 18:00", () => {
    const now = new Date("2026-10-18T14:00:00Z");
    expect(digestsDueAt(now, "Asia/Dubai", 18)).toEqual(["daily", "weekly"]);
    expect(digestsDueAt(now, "UTC", 18)).toEqual([]);
  });

  it("18:00Z Sunday: UTC sends; Dubai is at 22:00 and only the period key stops a resend", () => {
    const dubaiMorning = new Date("2026-10-18T14:00:00Z");
    const dubaiEvening = new Date("2026-10-18T18:00:00Z");
    expect(digestsDueAt(dubaiEvening, "UTC", 18)).toEqual(["daily", "weekly"]);
    // Both instants are past 18:00 local in Dubai...
    expect(digestsDueAt(dubaiEvening, "Asia/Dubai", 18)).toEqual(["daily", "weekly"]);
    // ...and they resolve to the same weekly period, which is what the send table keys on.
    expect(digestPeriod("weekly", localParts(dubaiMorning, "Asia/Dubai"))).toBe(
      digestPeriod("weekly", localParts(dubaiEvening, "Asia/Dubai")),
    );
  });

  it("the at-or-past rule sends at the next hour when DST deletes the configured one", () => {
    // Europe/London springs forward on 2026-03-29 at 01:00Z: local 00:59 -> 02:00, so local hour 01
    // never happens. With DIGEST_HOUR=1 the digest must still go out that day.
    const beforeJump = new Date("2026-03-29T00:30:00Z"); // local 00:30
    const afterJump = new Date("2026-03-29T01:30:00Z"); // local 02:30
    expect(localParts(beforeJump, "Europe/London").hour).toBe(0);
    expect(digestsDueAt(beforeJump, "Europe/London", 1)).toEqual([]);
    expect(localParts(afterJump, "Europe/London").hour).toBe(2);
    expect(digestsDueAt(afterJump, "Europe/London", 1)).toContain("daily");
  });

  it("a repeated fall-back hour resolves to one period, so it cannot send twice", () => {
    // Europe/London falls back on 2026-10-25 at 01:00Z: local 01:00 happens twice.
    const first = new Date("2026-10-25T00:30:00Z"); // local 01:30 BST
    const second = new Date("2026-10-25T01:30:00Z"); // local 01:30 GMT
    const a = digestPeriod("weekly", localParts(first, "Europe/London"));
    const b = digestPeriod("weekly", localParts(second, "Europe/London"));
    expect(a).toBe(b);
  });

  it("Sunday is the local Sunday, not the server's", () => {
    const saturdayInUtc = new Date("2026-10-17T22:00:00Z"); // Dubai: Sunday 02:00
    // In UTC it is still Saturday: the daily digest may be due, the weekly one may not.
    expect(digestsDueAt(saturdayInUtc, "UTC", 0)).toEqual(["daily"]);
    expect(digestsDueAt(saturdayInUtc, "Asia/Dubai", 0)).toEqual(["daily", "weekly"]);
  });
});

describe("periods", () => {
  it("uses the ISO week of the local Thursday across a year boundary", () => {
    expect(isoWeekKey("2026", "12", "31")).toBe(isoWeekKey("2027", "01", "01"));
    expect(isoWeekKey("2026", "10", "18")).toBe("2026-W42");
  });

  it("daily period is the local date", () => {
    expect(digestPeriod("daily", localParts(new Date("2026-10-18T23:00:00Z"), "Asia/Dubai"))).toBe("2026-10-19");
  });
});

describe("configuration", () => {
  it("DIGEST_HOUR is a local hour and defaults to 18", () => {
    expect(digestHour({} as NodeJS.ProcessEnv)).toBe(18);
    expect(digestHour({ DIGEST_HOUR: "7" } as NodeJS.ProcessEnv)).toBe(7);
    expect(digestHour({ DIGEST_HOUR: "99" } as NodeJS.ProcessEnv)).toBe(18);
  });

  it("DIGEST_HOUR is the family's LOCAL hour end to end, and the old UTC name resolves to it (F3)", () => {
    const hour = digestHour({ DIGEST_HOUR: "7" } as NodeJS.ProcessEnv);
    const at07InDubai = new Date("2026-10-18T03:00:00Z"); // Sunday 07:00 in Dubai, 03:00 UTC
    expect(digestsDueAt(at07InDubai, "Asia/Dubai", hour)).toEqual(["daily", "weekly"]);
    expect(digestsDueAt(at07InDubai, "UTC", hour)).toEqual([]); // 03:00 UTC is not 07:00

    // The pre-ADR-0017 name is a deprecated alias, read as the same local hour; the new name wins.
    expect(digestHour({ DIGEST_HOUR_UTC: "7" } as NodeJS.ProcessEnv)).toBe(7);
    expect(digestHour({ DIGEST_HOUR: "9", DIGEST_HOUR_UTC: "7" } as NodeJS.ProcessEnv)).toBe(9);
  });

  it("warns at boot when only the deprecated DIGEST_HOUR_UTC is set", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    startDigestScheduler({ JOBS_ENABLED: "1", DIGEST_HOUR_UTC: "18" } as NodeJS.ProcessEnv);
    expect(warn.mock.calls.flat().join(" ")).toContain("DIGEST_HOUR_UTC is deprecated");
    stopDigestScheduler();
    warn.mockRestore();
    log.mockRestore();
  });
});
