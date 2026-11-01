/**
 * ADR-0034 decision 1 (with the 2026-10-26 amendment): the one capability vocabulary a device reports
 * and the server stores.
 *
 * **Computed on the device, never derived on the server.** The agent is the only thing that knows whether
 * the lock screen can show on *this* phone — three paths can do it and the right one depends on grants, on
 * whether the service is bound, and on the OEM. The server repeats the agent's verdict, and decides only
 * one thing itself: which features a **build** cannot do at all (`not_supported`), from a static table in
 * `services/api/src/lib/capabilityTable.ts` (A1). A device that reports `not_supported` outside its table
 * row is shown as `unavailable`.
 */

/** The clients that report. Order is the ADR's; it is not a priority. */
export const CAPABILITY_APPS = ["child-android", "child-ios", "agent-desktop", "agent-macos"] as const;
export type CapabilityApp = (typeof CAPABILITY_APPS)[number];

/**
 * Build flavours. Android has two artefacts (ADR-0016 §4); iOS has three environments, which A7 will read
 * to pick an APNs host later; a desktop build is its own thing.
 */
export const CAPABILITY_FLAVOURS = ["play", "full", "dev", "testflight", "appstore"] as const;
export type CapabilityFlavour = (typeof CAPABILITY_FLAVOURS)[number];

/**
 * The grants a platform asks for, one entry per key the platform actually has.
 *
 * Android's are the wire names of `OnboardingPolicy.Grant`, plus `full_screen_intent` where #368 adds it;
 * iOS's three are A6's (`family_controls`, `location`, `background_refresh`). `USB debugging off` is a
 * grant on the same list and belongs here for the same reason: the parent's setup screen lists it.
 */
export const GRANT_KEYS = [
  "accessibility",
  "usage_access",
  "overlay",
  "device_admin",
  "web_filter",
  "location",
  "private_dns",
  "battery",
  "usb_debugging",
  "notification_listener",
  "full_screen_intent",
  "family_controls",
  "background_refresh",
] as const;
export type GrantKey = (typeof GRANT_KEYS)[number];

/** One grant's state. `not_applicable` is for a key the platform has but this build never asks for. */
export const GRANT_STATES = ["granted", "missing", "not_applicable"] as const;
export type GrantState = (typeof GRANT_STATES)[number];

/**
 * The fixed feature list, in the ADR's order.
 *
 * `degraded` means the feature works by a weaker path the agent's own policy still acknowledges as
 * applied — not "it might work". `unavailable` means it cannot work on this phone as things stand, and is
 * a fault. `not_supported` means the build cannot do it at all, and is the server's word (A1), not the
 * device's.
 */
export const FEATURE_KEYS = [
  "lock_screen",
  "pause_screen",
  "app_blocking",
  "screen_time",
  "web_filter",
  "pause_internet",
  "location",
  "uninstall_guard",
  "notification_scan",
  "call_sms_log",
] as const;
export type FeatureKey = (typeof FEATURE_KEYS)[number];

export const FEATURE_STATES = ["ready", "degraded", "unavailable", "not_supported"] as const;
export type FeatureState = (typeof FEATURE_STATES)[number];

/** The client block: which build is reporting, in the one shape the version gate reads. */
export interface CapabilityClient {
  app: CapabilityApp;
  /** Semver of the build, e.g. `0.2.0`. */
  version: string;
  /** The integer that orders releases (`versionCode` on Android). */
  build: number;
  flavour: CapabilityFlavour;
}

/**
 * osra-security#6 item 2: the kinds of "other space" a phone can hold besides the child's own user.
 *
 * `clone` is Android's `android.os.usertype.profile.CLONE` (Samsung Dual Messenger, user 95 on the Flip4),
 * `work` is `android.os.usertype.profile.MANAGED`. `secure_folder` is reserved: no capture has shown a
 * set-up Secure Folder's user type yet, so nothing maps to it, and a Knox user is reported as `other`.
 * `other` is any profile whose type the agent cannot name — including every profile below API 35, where a
 * normal app cannot read the type at all.
 */
export const PROFILE_KINDS = ["work", "clone", "secure_folder", "other"] as const;
export type ProfileKind = (typeof PROFILE_KINDS)[number];

/** The most other profiles a report may claim. Android caps users per device well below this. */
export const PROFILES_MAX_OTHERS = 8;

/**
 * Other users and profiles on the phone: **counts and kinds only** — never user ids, names or app lists.
 *
 * `kinds` is a set (no duplicates, at most `others` entries), and is never empty while `others > 0`: a
 * profile whose type is unknown is `other`, so the parent's Phone setup row cannot read as clean.
 */
export interface DeviceProfiles {
  others: number;
  kinds: ProfileKind[];
}

/** ADR-0034 decision 1: the whole report. */
export interface DeviceCapabilitiesV1 {
  client: CapabilityClient;
  grants: Partial<Record<GrantKey, GrantState>>;
  features: Partial<Record<FeatureKey, FeatureState>>;
  /**
   * osra-security#6 item 2, optional on the wire: a report without it leaves the stored value alone, the
   * same rule decision 2 sets for the whole report, so an agent that cannot read profiles never erases what
   * one that could said.
   */
  profiles?: DeviceProfiles;
}

/** The largest serialized report the server accepts (A2). */
export const CAPABILITIES_MAX_BYTES = 4096;

/**
 * What `GET /v1/devices` and `GET /v1/devices/:id` add for the parent's "Phone setup" screen (decision 3).
 *
 * [stale] is the server's judgement, not the device's: a report older than one telemetry period plus its
 * flex (20 minutes, A4) is shown with its age and is **never** used to refuse a command.
 */
export interface DeviceSetup {
  reportedAt: string | null;
  stale: boolean;
  features: Partial<Record<FeatureKey, FeatureState>>;
  /** The grants the device reported as `missing` — the "what to fix" list. */
  missing: GrantKey[];
  /** osra-security#6 item 2: the last reported other spaces, or null when no report has carried them. */
  profiles: DeviceProfiles | null;
}
