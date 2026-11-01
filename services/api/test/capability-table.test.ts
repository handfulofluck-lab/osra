import { describe, expect, it } from "vitest";
import { FEATURE_KEYS } from "@familyshield/shared-types";
import { capabilityTableRows, isNotSupported, shownFeatureState } from "../src/lib/capabilityTable.js";

/**
 * ADR-0034 A1: `not_supported` is the **server's** word, from a table of build facts.
 *
 * One case per table entry, as the ADR asks ("each row has a unit test"), plus the claim-8 property that
 * gives the table its teeth: a device that reports `not_supported` outside its own row is shown as
 * `unavailable`, so a modified agent cannot turn a fault into a quiet grey row.
 */
describe("ADR-0034 A1 — the not_supported table", () => {
  it("has one case per row, and every feature it names is in the shared vocabulary", () => {
    const rows = capabilityTableRows();
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) {
      for (const feature of row.features) {
        expect(FEATURE_KEYS).toContain(feature);
        expect(
          isNotSupported(row.app, row.flavour, feature),
          `${row.app}/${row.flavour} must report ${feature} as not_supported`,
        ).toBe(true);
      }
    }
  });

  it("Play cannot log calls or texts, and the Full build can", () => {
    // ADR-0016 §4: the Play artefact declares neither READ_CALL_LOG nor READ_SMS, and has no
    // NotificationListenerService — the two reasons the build cannot do these at all.
    expect(isNotSupported("child-android", "play", "call_sms_log")).toBe(true);
    expect(isNotSupported("child-android", "play", "notification_scan")).toBe(true);
    expect(isNotSupported("child-android", "full", "call_sms_log")).toBe(false);
    expect(isNotSupported("child-android", "full", "notification_scan")).toBe(false);
  });

  it("iOS cannot lock, pause, uninstall-guard or read calls, in every flavour", () => {
    for (const flavour of ["dev", "testflight", "appstore"]) {
      for (const feature of ["lock_screen", "pause_screen", "pause_internet", "uninstall_guard", "notification_scan", "call_sms_log"] as const) {
        expect(isNotSupported("child-ios", flavour, feature), `child-ios/${flavour} ${feature}`).toBe(true);
      }
    }
  });

  it("an unknown build is never declared not_supported", () => {
    // An app or flavour the table does not know must not grey anything out: silence is the safe answer,
    // and a wrong row would hide a fault behind a "not supported" label.
    expect(isNotSupported("child-android", "testflight", "lock_screen")).toBe(false);
    expect(isNotSupported(null, null, "lock_screen")).toBe(false);
    expect(isNotSupported("parent-app", "android", "lock_screen")).toBe(false);
  });

  it("claim 8: a device claiming not_supported outside its row is shown as unavailable", () => {
    // The Full build CAN run the lock screen, so a report saying it cannot is not believed.
    expect(shownFeatureState("child-android", "full", "lock_screen", "not_supported")).toBe("unavailable");
    // Inside the row it is believed, and it is the table that says so, not the device.
    expect(shownFeatureState("child-android", "play", "call_sms_log", "not_supported")).toBe("not_supported");
    // Everything else passes through untouched.
    expect(shownFeatureState("child-android", "full", "lock_screen", "available")).toBe("available");
    expect(shownFeatureState("child-android", "full", "lock_screen", "degraded")).toBe("degraded");
    expect(shownFeatureState("child-android", "full", "lock_screen", null)).toBeNull();
  });
});
