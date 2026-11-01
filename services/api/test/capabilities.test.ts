import { describe, expect, it } from "vitest";
import {
  CAPABILITIES_MAX_AGE_MS,
  CapabilitiesSchema,
  commandRefusal,
  parseCapabilities,
  setupFor,
} from "../src/lib/capabilities.js";

/**
 * ADR-0034 PR 1a — the report's shape, what a parent is shown, and the one refusal.
 *
 * Claim numbers are the ADR's, so a reviewer can go from a failing row to the sentence it protects.
 */

const NOW = Date.UTC(2026, 10, 1, 12, 0, 0);

function report(overrides: Record<string, unknown> = {}) {
  return {
    client: { app: "child-android", version: "0.2.0", build: 2, flavour: "full" },
    grants: { accessibility: "granted", overlay: "missing", usage_access: "granted" },
    features: {
      lock_screen: "ready",
      pause_screen: "ready",
      app_blocking: "ready",
      screen_time: "ready",
      web_filter: "ready",
      pause_internet: "ready",
      location: "ready",
      uninstall_guard: "ready",
      notification_scan: "ready",
      call_sms_log: "ready",
    },
    ...overrides,
  };
}

describe("A2 — the schema is strict, enum-keyed and capped", () => {
  it("accepts the shape the ADR describes", () => {
    expect(CapabilitiesSchema.safeParse(report()).success).toBe(true);
  });

  it("claim 9 — an unknown key, an unknown grant or an unknown feature is refused", () => {
    expect(CapabilitiesSchema.safeParse(report({ extra: true })).success).toBe(false);
    expect(
      CapabilitiesSchema.safeParse(report({ grants: { accessibility: "granted", telepathy: "granted" } })).success,
    ).toBe(false);
    expect(CapabilitiesSchema.safeParse(report({ features: { lock_screen: "sometimes" } })).success).toBe(false);
    expect(CapabilitiesSchema.safeParse(report({ client: { ...report().client, mood: "good" } })).success).toBe(false);
  });

  it("claim 9 — an object over the 4 KB cap is refused by the cap, not by a field rule", () => {
    // The cap cannot be reached by valid data (enum keys, short values), so it can only be tested on the
    // RAW object — which is exactly what it exists to bound. Claude's f3 (delete the cap) survived every
    // row until this one existed.
    const raw: Record<string, unknown> = { ...report() };
    for (let i = 0; i < 200; i++) raw[`k${i}`] = "x".repeat(40);
    expect(Buffer.byteLength(JSON.stringify(raw))).toBeGreaterThan(4096);
    const parsed = parseCapabilities(raw);
    expect(parsed.ok).toBe(false);
    expect(parsed.ok ? "" : parsed.issue).toContain("the cap is 4096");
  });

  it("claim 11 — a timestamp inside the object is not part of the contract, so it is refused", () => {
    // A4: the server's receipt time is the only freshness clock. `.strict()` is how a device-supplied
    // one never gets read — not by being ignored, but by making its presence a parse error.
    expect(CapabilitiesSchema.safeParse(report({ reportedAt: new Date(NOW).toISOString() })).success).toBe(false);
    expect(CapabilitiesSchema.safeParse(report({ timestamp: NOW })).success).toBe(false);
  });
});

describe("decision 3 + A4 — what the parent's setup screen is shown", () => {
  it("a fresh report is not stale and lists the missing grants", () => {
    const setup = setupFor({ capabilities: report(), capabilitiesReportedAt: new Date(NOW - 60_000) }, NOW);
    expect(setup.stale).toBe(false);
    expect(setup.reportedAt).toBe(new Date(NOW - 60_000).toISOString());
    expect(setup.missing).toEqual(["overlay"]);
    expect(setup.features.lock_screen).toBe("ready");
  });

  it("a report older than 20 minutes is stale, and still shown", () => {
    const setup = setupFor({ capabilities: report(), capabilitiesReportedAt: new Date(NOW - CAPABILITIES_MAX_AGE_MS - 1) }, NOW);
    expect(setup.stale).toBe(true);
    expect(setup.features.lock_screen).toBe("ready");
  });

  it("a device that has never reported is not 'all missing'", () => {
    const setup = setupFor({ capabilities: null, capabilitiesReportedAt: null }, NOW);
    expect(setup).toEqual({ reportedAt: null, stale: true, features: {}, missing: [] });
  });

  it("claim 8 — a not_supported claimed outside the build's row is shown as unavailable", () => {
    // The Full build can run the lock screen, so its claim is not believed...
    const lying = report({ features: { ...report().features, lock_screen: "not_supported" } });
    expect(setupFor({ capabilities: lying, capabilitiesReportedAt: new Date(NOW) }, NOW).features.lock_screen).toBe(
      "unavailable",
    );
    // ...while the Play build's call-log claim is the table's own word, so it stays grey rather than red.
    const play = report({
      client: { app: "child-android", version: "0.2.0", build: 2, flavour: "play" },
      features: { ...report().features, call_sms_log: "not_supported" },
    });
    expect(setupFor({ capabilities: play, capabilitiesReportedAt: new Date(NOW) }, NOW).features.call_sms_log).toBe(
      "not_supported",
    );
  });
});

describe("decision 3 + A1 — when a command is refused instead of queued", () => {
  it("a lock with a fresh unavailable report is refused with the agent's own reason", () => {
    const r = report({ features: { ...report().features, lock_screen: "unavailable" } });
    expect(commandRefusal({ capabilities: r, capabilitiesReportedAt: new Date(NOW - 60_000) }, "lock", NOW)).toEqual({
      reason: "lock_screen_unavailable",
    });
  });

  it("the same lock at 21 minutes is queued, not refused", () => {
    // Issue #221's rule, generalised: a refusal on a stale report tells a parent to fix something the
    // child may already have fixed.
    const r = report({ features: { ...report().features, lock_screen: "unavailable" } });
    expect(
      commandRefusal({ capabilities: r, capabilitiesReportedAt: new Date(NOW - CAPABILITIES_MAX_AGE_MS - 1) }, "lock", NOW),
    ).toBeNull();
  });

  it("a degraded report queues: the agent applies a weaker path itself", () => {
    const r = report({ features: { ...report().features, lock_screen: "degraded" } });
    expect(commandRefusal({ capabilities: r, capabilitiesReportedAt: new Date(NOW) }, "lock", NOW)).toBeNull();
  });

  it("claim 13 — a lock to an iPhone is refused from the table, whatever the report's age", () => {
    // A6: the table does not age. This is the case that matters most on iOS, where telemetry has no timer,
    // so a report is often older than 20 minutes and the freshness rule would never fire.
    const ios = report({
      client: { app: "child-ios", version: "0.1.0", build: 1, flavour: "testflight" },
      features: {},
    });
    expect(commandRefusal({ capabilities: ios, capabilitiesReportedAt: null }, "lock", NOW)).toEqual({
      reason: "not_supported",
    });
    expect(
      commandRefusal({ capabilities: ios, capabilitiesReportedAt: new Date(NOW - 10 * CAPABILITIES_MAX_AGE_MS) }, "lock", NOW),
    ).toEqual({ reason: "not_supported" });
  });

  it("commands with no feature behind them are always queued", () => {
    // `ring` and `unlock` have no entry in the ten features, so nothing can honestly refuse them.
    const r = report({ features: { ...report().features, lock_screen: "unavailable" } });
    expect(commandRefusal({ capabilities: r, capabilitiesReportedAt: new Date(NOW) }, "ring", NOW)).toBeNull();
    expect(commandRefusal({ capabilities: r, capabilitiesReportedAt: new Date(NOW) }, "unlock", NOW)).toBeNull();
    expect(commandRefusal({ capabilities: r, capabilitiesReportedAt: new Date(NOW) }, "screenshot", NOW)).toBeNull();
  });

  it("a device that never reported is never refused", () => {
    expect(commandRefusal({ capabilities: null, capabilitiesReportedAt: null }, "lock", NOW)).toBeNull();
  });
});
