import type { CapabilityApp, CapabilityFlavour, FeatureKey } from "@familyshield/shared-types";

/**
 * ADR-0034 A1: which features a **build** cannot do at all, as a static table keyed by (app, flavour).
 *
 * **Why the server holds this and not the device.** Decision 1 lets the parent app grey a
 * `not_supported` feature out and not report it as a fault. If the device chose that word, a modified
 * agent could mark `lock_screen` or `web_filter` as `not_supported` and turn a fault into a quiet grey
 * row. The one-vocabulary rule is untouched: `not_supported` is a fact about the build, not a verdict
 * about this phone's state, so the server holds it — and a device that claims it outside its row is
 * stored, shown as `unavailable`, and counted as a fault (claim 8).
 *
 * **The table does not age.** A build fact is as true an hour later, so the 20-minute freshness guard of
 * decision 2 does not apply to it: a command whose feature the table marks `not_supported` is recorded
 * failed at once, from the table, without waking the phone, whatever the report's age (claim 13). That
 * matters most on iOS, where telemetry has no timer (A6).
 */

/** What a build cannot do, by (app, flavour). A missing pair means "the build can do everything". */
const NOT_SUPPORTED: Record<CapabilityApp, Partial<Record<CapabilityFlavour, readonly FeatureKey[]>>> = {
  // ADR-0016 §4: the Play artefact declares neither READ_CALL_LOG nor READ_SMS and has no
  // NotificationListenerService, so two features do not exist in it. Advertising them on Play would also
  // show a store reviewer a request the build cannot use.
  "child-android": {
    play: ["call_sms_log", "notification_scan"],
  },
  // A6: no public iOS API for any of these. `notification_scan` and `call_sms_log` are Android words here
  // too — iOS has silent push, so notification access is not a grant it asks for.
  "child-ios": {
    dev: ["lock_screen", "pause_screen", "pause_internet", "uninstall_guard", "notification_scan", "call_sms_log"],
    testflight: ["lock_screen", "pause_screen", "pause_internet", "uninstall_guard", "notification_scan", "call_sms_log"],
    appstore: ["lock_screen", "pause_screen", "pause_internet", "uninstall_guard", "notification_scan", "call_sms_log"],
  },
  // The desktop agent runs the Windows web filter proxy; it cannot lock a phone's screen, and it has no
  // call or SMS log at all. Filled in when roadmap 5.4 has a build to name; an empty row is the honest
  // value until then, and a wrong row would grey out a fault.
  "agent-desktop": {},
  "agent-macos": {},
};

/** True when this (app, flavour) cannot do [feature] at all. */
export function isNotSupported(
  app: string | null | undefined,
  flavour: string | null | undefined,
  feature: FeatureKey,
): boolean {
  if (!app || !flavour) return false;
  const row = NOT_SUPPORTED[app as CapabilityApp]?.[flavour as CapabilityFlavour];
  return row?.includes(feature) ?? false;
}

/**
 * The state a stored feature is **shown** with.
 *
 * A device's `not_supported` is only believed inside its own table row; anywhere else it is a claim the
 * build cannot back, so it is shown as `unavailable` — a fault, not a grey row (claim 8).
 */
export function shownFeatureState(
  app: string | null | undefined,
  flavour: string | null | undefined,
  feature: FeatureKey,
  reported: string | null | undefined,
): string | null {
  if (reported == null) return null;
  if (isNotSupported(app, flavour, feature)) return "not_supported";
  return reported === "not_supported" ? "unavailable" : reported;
}

/** Every (app, flavour) row, for the test that holds one case per entry. */
export function capabilityTableRows(): Array<{ app: CapabilityApp; flavour: CapabilityFlavour; features: readonly FeatureKey[] }> {
  const out: Array<{ app: CapabilityApp; flavour: CapabilityFlavour; features: readonly FeatureKey[] }> = [];
  for (const [app, byFlavour] of Object.entries(NOT_SUPPORTED)) {
    for (const [flavour, features] of Object.entries(byFlavour)) {
      out.push({ app: app as CapabilityApp, flavour: flavour as CapabilityFlavour, features: features ?? [] });
    }
  }
  return out;
}
