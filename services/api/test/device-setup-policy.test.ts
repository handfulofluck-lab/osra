import { describe, expect, it } from "vitest";
import type { Capabilities } from "../src/lib/capabilities.js";
import {
  SETUP_WINDOW_MS,
  completionDedupeKey,
  incompleteDedupeKey,
  requiredMissingGrants,
  setupIncompleteDue,
  shouldHoldTamperDuringSetup,
} from "../src/lib/deviceSetup.js";

const START = new Date("2026-11-26T01:00:00.000Z");
const BEFORE_EXPIRY = new Date(START.getTime() + SETUP_WINDOW_MS - 1);
const AT_EXPIRY = new Date(START.getTime() + SETUP_WINDOW_MS);

function android(grants: Capabilities["grants"]): Capabilities {
  return {
    client: { app: "child-android", version: "0.2.0", build: 42, flavour: "full" },
    grants,
    features: {},
  };
}

const ALL_REQUIRED = {
  accessibility: "granted",
  usage_access: "granted",
  overlay: "granted",
  device_admin: "granted",
  web_filter: "granted",
  location: "granted",
  private_dns: "granted",
} as const;

function device(overrides: Record<string, unknown> = {}) {
  return {
    id: "dev-1",
    pairedAt: START,
    setupCompletedAt: null,
    capabilities: android({ ...ALL_REQUIRED, accessibility: "missing" }),
    ...overrides,
  };
}

describe("server-owned setup policy (#1127)", () => {
  it("requires all seven Android grants but not recommended grants", () => {
    expect(requiredMissingGrants(android({
      ...ALL_REQUIRED,
      battery: "missing",
      usb_debugging: "missing",
      notification_listener: "missing",
    }))).toEqual([]);
    expect(requiredMissingGrants(android({ ...ALL_REQUIRED, overlay: "missing" }))).toEqual(["overlay"]);
    expect(requiredMissingGrants(android({ ...ALL_REQUIRED, location: "not_applicable" }))).toEqual(["location"]);
    const { web_filter: _omitted, ...withoutWebFilter } = ALL_REQUIRED;
    expect(requiredMissingGrants(android(withoutWebFilter))).toEqual(["web_filter"]);
  });

  it("does not treat an unknown report or another platform as complete", () => {
    expect(requiredMissingGrants(null)).toBeNull();
    expect(requiredMissingGrants({ not: "a capability report" })).toBeNull();
    expect(requiredMissingGrants({
      ...android({}),
      client: { app: "child-ios", version: "0.2.0", build: 42, flavour: "testflight" },
    })).toBeNull();
  });

  it("holds only an exact grant-linked tamper type while that grant is missing", () => {
    const cases = [
      ["accessibility_off", "accessibility"],
      ["accessibility", "accessibility"],
      ["device_admin_removed", "device_admin"],
      ["content_filter_disconnected", "web_filter"],
      ["overlay_revoked", "overlay"],
      ["usage_access_off", "usage_access"],
      ["notification_listener_off", "notification_listener"],
    ] as const;
    for (const [type, grant] of cases) {
      const row = device({ capabilities: android({ ...ALL_REQUIRED, [grant]: "missing" }) });
      expect(shouldHoldTamperDuringSetup(row, "tamper", type, BEFORE_EXPIRY), type).toBe(true);
      const ready = device({ capabilities: android(ALL_REQUIRED) });
      expect(shouldHoldTamperDuringSetup(ready, "tamper", type, BEFORE_EXPIRY), `${type}: ready`).toBe(false);
    }
  });

  it("fails visible for unrelated, unknown, or explicitly never-held events", () => {
    const types = [
      "agent_data_cleared",
      "replaced",
      "reinstalled",
      "clock_changed",
      "timezone_changed",
      "safe_mode",
      "protection_screen_opened",
      "parent_pin_locked",
      "block_bypass",
      "private_dns_bypass",
      "something_new",
    ];
    for (const type of types) {
      expect(shouldHoldTamperDuringSetup(device(), "tamper", type, BEFORE_EXPIRY), type).toBe(false);
    }
    expect(shouldHoldTamperDuringSetup(device(), "sos", "accessibility_off", BEFORE_EXPIRY)).toBe(false);
    expect(shouldHoldTamperDuringSetup(device(), "vpn_detected", "content_filter_disconnected", BEFORE_EXPIRY)).toBe(false);
    expect(shouldHoldTamperDuringSetup(device({ capabilities: null }), "tamper", "accessibility_off", BEFORE_EXPIRY)).toBe(false);
  });

  it("uses pairedAt and server receipt time, closing at exactly 30 minutes", () => {
    expect(shouldHoldTamperDuringSetup(device(), "tamper", "accessibility_off", BEFORE_EXPIRY)).toBe(true);
    expect(shouldHoldTamperDuringSetup(device(), "tamper", "accessibility_off", AT_EXPIRY)).toBe(false);
    expect(shouldHoldTamperDuringSetup(device({ pairedAt: null }), "tamper", "accessibility_off", BEFORE_EXPIRY)).toBe(false);
    expect(shouldHoldTamperDuringSetup(device({ setupCompletedAt: BEFORE_EXPIRY }), "tamper", "accessibility_off", BEFORE_EXPIRY)).toBe(false);
  });

  it("makes the one incomplete alert due at the boundary and keys both transitions by setup episode", () => {
    expect(setupIncompleteDue(device(), BEFORE_EXPIRY)).toBe(false);
    expect(setupIncompleteDue(device(), AT_EXPIRY)).toBe(true);
    expect(setupIncompleteDue(device({ setupCompletedAt: AT_EXPIRY }), AT_EXPIRY)).toBe(false);
    expect(setupIncompleteDue(device({ pairedAt: null }), AT_EXPIRY)).toBe(false);
    expect(completionDedupeKey("dev-1", START)).toBe(completionDedupeKey("dev-1", START));
    expect(incompleteDedupeKey("dev-1", START)).toBe(incompleteDedupeKey("dev-1", START));
    expect(completionDedupeKey("dev-1", START)).not.toBe(incompleteDedupeKey("dev-1", START));
    expect(completionDedupeKey("dev-1", START)).not.toBe(completionDedupeKey("dev-2", START));
  });
});
