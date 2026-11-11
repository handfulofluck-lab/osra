import { z } from "zod";
import {
  CAPABILITIES_MAX_BYTES,
  CAPABILITY_APPS,
  CAPABILITY_FLAVOURS,
  FEATURE_KEYS,
  FEATURE_STATES,
  GRANT_KEYS,
  GRANT_STATES,
  APP_GROUP_COUNT_MAX,
  APP_GROUP_LABEL_MAX,
  APP_GROUPS_MAX,
  APP_GROUPS_MAX_BYTES,
  PROFILE_KINDS,
  PROFILES_MAX_OTHERS,
  type CapabilityApp,
  type DeviceSetup,
  type FeatureKey,
} from "@familyshield/shared-types";
import { isCommandNotSupported, isNotSupported, shownFeatureState } from "./capabilityTable.js";

/**
 * ADR-0034 PR 1a: the capability report, its storage rules, and the one refusal that replaces
 * `locateNowRefusal`.
 *
 * Three things live here because they are the same decision seen from three sides:
 *  * what a device may send ([CapabilitiesSchema], A2: `.strict()`, enum keys and values, 4 KB);
 *  * how it is shown to a parent ([setupFor], decision 3 + A4: the server's clock, never the device's);
 *  * when a command is refused instead of queued ([commandRefusal], decision 3 + A1).
 */

/**
 * osra-security#6 item 2: other users and profiles, counts and kinds only.
 *
 * `kinds` is a set of at most `others` entries, and never empty while `others > 0`, so an unknown profile
 * is still a row on the parent's Phone setup screen rather than a clean one. `others: 0` carries no kinds.
 */
export const ProfilesSchema = z
  .object({
    others: z.number().int().min(0).max(PROFILES_MAX_OTHERS),
    kinds: z.array(z.enum(PROFILE_KINDS)).max(PROFILE_KINDS.length),
  })
  .strict()
  .superRefine((value, ctx) => {
    if (new Set(value.kinds).size !== value.kinds.length) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["kinds"], message: "kinds must not repeat" });
    }
    if (value.kinds.length > value.others) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["kinds"], message: "more kinds than others" });
    }
    if (value.others > 0 && value.kinds.length === 0) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["kinds"], message: "others > 0 needs at least one kind (\"other\" when unknown)" });
    }
  });

/**
 * ADR-0037 (5.5 PR B): an iPhone app group, id + label + counts. The label is child-phone input: the phone cleans it,
 * and this checks it again (no control characters, no edge whitespace, 1-40 characters). It is never logged: no
 * message below repeats it.
 */
// eslint-disable-next-line no-control-regex
const CONTROL_CHARS = /[\u0000-\u001f\u007f-\u009f]/;
const countSchema = z.number().int().min(0).max(APP_GROUP_COUNT_MAX);
export const AppGroupSchema = z
  .object({
    id: z.string().uuid(),
    label: z
      .string()
      .min(1)
      .refine((v) => [...v].length <= APP_GROUP_LABEL_MAX, { message: `label is over ${APP_GROUP_LABEL_MAX} characters` })
      .refine((v) => !CONTROL_CHARS.test(v), { message: "label has control characters" })
      .refine((v) => v.trim() === v && v.length > 0, { message: "label has edge whitespace" }),
    apps: countSchema,
    categories: countSchema,
    sites: countSchema,
  })
  .strict();

export const AppGroupsSchema = z
  .array(AppGroupSchema)
  .max(APP_GROUPS_MAX)
  .superRefine((groups, ctx) => {
    if (new Set(groups.map((g) => g.id.toLowerCase())).size !== groups.length) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: "group ids must not repeat" });
    }
  });

/** The report without its groups, which have a cap of their own (`APP_GROUPS_MAX_BYTES`). */
function withoutGroups(value: unknown): unknown {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return value;
  const { groups: _groups, ...rest } = value as Record<string, unknown>;
  return rest;
}

/** A2: enum keys, enum values, nothing else, and a cap on the serialized object. */
export const CapabilitiesSchema = z
  .object({
    client: z
      .object({
        app: z.enum(CAPABILITY_APPS),
        version: z.string().min(1).max(24),
        build: z.number().int().min(0),
        flavour: z.enum(CAPABILITY_FLAVOURS),
      })
      .strict(),
    // `z.record` with an enum key validates every key against it, so an unknown grant or feature is a
    // parse error rather than a field the server quietly keeps.
    grants: z.record(z.enum(GRANT_KEYS), z.enum(GRANT_STATES)),
    features: z.record(z.enum(FEATURE_KEYS), z.enum(FEATURE_STATES)),
    // Optional: an agent that cannot read profiles omits it, and [withStoredProfiles] keeps the last value.
    profiles: ProfilesSchema.optional(),
    // ADR-0037: iPhone only; optional, and a report without it keeps the stored groups ([withStoredGroups]).
    groups: AppGroupsSchema.optional(),
  })
  .strict()
  .superRefine((value, ctx) => {
    if (value.groups !== undefined && value.client.app !== "child-ios") {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["groups"], message: "app groups are an iPhone report" });
    }
    const bytes = Buffer.byteLength(JSON.stringify(withoutGroups(value)), "utf8");
    if (bytes > CAPABILITIES_MAX_BYTES) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: `capabilities is ${bytes} bytes; the cap is ${CAPABILITIES_MAX_BYTES}`,
      });
    }
  });

export type Capabilities = z.infer<typeof CapabilitiesSchema>;

/**
 * A2's 4 KB cap, applied to the **raw** input before the schema sees it.
 *
 * The cap inside [CapabilitiesSchema] cannot be reached by schema-valid data: enum keys and short enum
 * values make a valid report well under a kilobyte. What the cap actually bounds is the raw object an
 * agent posts — a hostile one can be any size, and `.strict()` would only reject it *after* parsing it.
 * Claude's f3 (delete the cap) survived every row until this existed, which is what a dead guard looks
 * like: it is checked last, on data that already passed.
 */
export function capabilitiesInputBytes(raw: unknown): number | null {
  try {
    return Buffer.byteLength(JSON.stringify(raw), "utf8");
  } catch {
    return null; // an unserializable value is the schema's problem, not the cap's
  }
}

/**
 * A1 rests on `client.app`, so it must be the app this device actually is. Without this check a modified
 * Android agent could report `child-ios` and have the server grey `lock_screen` out as `not_supported`
 * and refuse every lock from the table: the exact fault-into-grey-row A1 exists to stop. The platform
 * comes from the pairing claim and the Device row, never from the report.
 */
const APP_FOR_PLATFORM: Record<string, CapabilityApp | undefined> = {
  android: "child-android",
  ios: "child-ios",
  windows: "agent-desktop",
  macos: "agent-macos",
};

/** The one entry point the routes use: the cap first, the schema second, then the app must match the platform. */
export function parseCapabilities(
  raw: unknown,
  platform?: string | null,
): { ok: true; value: Capabilities } | { ok: false; issue: string } {
  const bytes = capabilitiesInputBytes(withoutGroups(raw));
  if (bytes != null && bytes > CAPABILITIES_MAX_BYTES) {
    return { ok: false, issue: `capabilities is ${bytes} bytes; the cap is ${CAPABILITIES_MAX_BYTES}` };
  }
  // ADR-0037: the groups' own cap, checked on the raw input before the schema parses it, like the report's.
  const groupsRaw = raw !== null && typeof raw === "object" ? (raw as Record<string, unknown>).groups : undefined;
  const groupBytes = groupsRaw === undefined ? 0 : capabilitiesInputBytes(groupsRaw);
  if (groupBytes != null && groupBytes > APP_GROUPS_MAX_BYTES) {
    return { ok: false, issue: `groups is ${groupBytes} bytes; the cap is ${APP_GROUPS_MAX_BYTES}` };
  }
  const parsed = CapabilitiesSchema.safeParse(raw);
  if (!parsed.success) {
    return {
      ok: false,
      issue: parsed.error.issues.map((i) => `${i.path.join(".") || "capabilities"}: ${i.message}`).join("; "),
    };
  }
  if (platform != null && APP_FOR_PLATFORM[platform] !== parsed.data.client.app) {
    return { ok: false, issue: `client.app: ${parsed.data.client.app} does not match this device (${platform})` };
  }
  return { ok: true, value: parsed.data };
}

/**
 * osra-security#6 item 2: a report without `profiles` keeps the stored one.
 *
 * Decision 2's rule for the whole report, applied one level down: the report replaces the stored one, but
 * an agent that cannot read profiles (or a build from before this field) must not erase what an agent that
 * could said. A stored value that no longer parses is dropped rather than carried.
 */
export function withStoredProfiles(next: Capabilities, stored: unknown): Capabilities {
  if (next.profiles !== undefined) return next;
  const previous = CapabilitiesSchema.safeParse(stored);
  if (!previous.success || previous.data.profiles === undefined) return next;
  return { ...next, profiles: previous.data.profiles };
}

/**
 * ADR-0037: a report without `groups` keeps the stored ones, the profiles rule again: an iPhone build that does not
 * send groups (older, or the PIN screen not reached) must not erase what a newer one said. An empty list replaces.
 */
export function withStoredGroups(next: Capabilities, stored: unknown): Capabilities {
  if (next.groups !== undefined) return next;
  const previous = CapabilitiesSchema.safeParse(stored);
  if (!previous.success || previous.data.groups === undefined) return next;
  return { ...next, groups: previous.data.groups };
}

/**
 * A4: how old a report may be and still describe the phone *now*.
 *
 * One telemetry period plus its flex, the same window issue #221 chose for `locationGrant`. A report
 * older than this is shown with its age and is **never** used to refuse a command: a refusal on a stale
 * report tells a parent to fix something the child may already have fixed.
 */
export const CAPABILITIES_MAX_AGE_MS = 20 * 60 * 1000;

function reportedAtMs(reportedAt: Date | string | null | undefined): number | null {
  if (reportedAt == null) return null;
  const ms = reportedAt instanceof Date ? reportedAt.getTime() : Date.parse(reportedAt);
  return Number.isFinite(ms) ? ms : null;
}

/** The slice of a Device row this module needs; keeps it testable without Prisma. */
export interface CapabilityReport {
  capabilities: unknown;
  capabilitiesReportedAt: Date | string | null;
}

/**
 * What `GET /v1/devices` and `GET /v1/devices/:id` add for the parent's "Phone setup" screen.
 *
 * `not_supported` is recomputed from the table (A1), so the screen cannot be talked into greying out a
 * fault by a modified agent; `stale` is the server's judgement (A4). A device that has never reported
 * yields `reportedAt: null, stale: true` and empty maps — shown as "not reported yet", never as "all
 * missing".
 */
export function setupFor(report: CapabilityReport, nowMs: number = Date.now()): DeviceSetup {
  const parsed = CapabilitiesSchema.safeParse(report.capabilities);
  const at = reportedAtMs(report.capabilitiesReportedAt);
  if (!parsed.success || at == null) {
    return { reportedAt: null, stale: true, features: {}, missing: [], profiles: null, groups: null };
  }
  const { client, grants, features, profiles, groups } = parsed.data;
  const shownFeatures: Partial<Record<FeatureKey, string>> = {};
  for (const [feature, state] of Object.entries(features)) {
    const shown = shownFeatureState(client.app, client.flavour, feature as FeatureKey, state);
    if (shown) shownFeatures[feature as FeatureKey] = shown;
  }
  return {
    reportedAt: new Date(at).toISOString(),
    stale: nowMs - at > CAPABILITIES_MAX_AGE_MS,
    features: shownFeatures as DeviceSetup["features"],
    missing: (Object.entries(grants) as Array<[keyof typeof grants, string]>)
      .filter(([, state]) => state === "missing")
      .map(([key]) => key as DeviceSetup["missing"][number]),
    profiles: profiles ?? null,
    groups: groups ?? null,
  };
}

/**
 * Which feature a command needs, for the refusal below.
 *
 * Only the commands whose effect is one of the ten features appear here. `ring` and `unlock` are
 * deliberately absent: no feature describes them, so nothing can honestly refuse them, and a queued
 * command that the phone answers is better than a guess (decision 3's own rule).
 */
const COMMAND_FEATURE: Record<string, FeatureKey> = {
  lock: "lock_screen",
  pause: "pause_screen",
  pause_internet: "pause_internet",
  locate_now: "location",
};

export interface CommandRefusal {
  reason: string;
}

/**
 * Why [command] cannot work on this device; null means "queue it".
 *
 * The two rules, in the ADR's order of certainty:
 *
 * 1. **The table, whatever the report's age (A1).** A feature the build cannot do at all is a fact about
 *    the build, so it does not age: refused at once, without waking the phone (claim 13).
 * 2. **A fresh report saying `unavailable`.** The reason carries the feature's own name —
 *    `lock_screen_unavailable` — because that is the string the agent's acknowledgement would carry, and
 *    the server must not grow a second vocabulary for one condition.
 *
 * `degraded` is never a refusal: the agent applies it, so failing the command would be the server
 * contradicting the phone. A stale report is never used to refuse, and an unknown feature is never
 * guessed at.
 */
export function commandRefusal(
  report: CapabilityReport,
  command: string,
  nowMs: number = Date.now(),
): CommandRefusal | null {
  const parsed = CapabilitiesSchema.safeParse(report.capabilities);
  if (!parsed.success) return null;
  const { client, features } = parsed.data;
  if (isCommandNotSupported(client.app, command)) return { reason: "not_supported" };
  const feature = COMMAND_FEATURE[command];
  if (!feature) return null;

  if (isNotSupported(client.app, client.flavour, feature)) return { reason: "not_supported" };

  const at = reportedAtMs(report.capabilitiesReportedAt);
  if (at == null || nowMs - at > CAPABILITIES_MAX_AGE_MS) return null;

  const state = shownFeatureState(client.app, client.flavour, feature, features[feature] ?? null);
  if (state === "unavailable") return { reason: `${feature}_unavailable` };
  return null;
}
