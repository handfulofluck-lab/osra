import { z } from "zod";
import {
  CAPABILITIES_MAX_BYTES,
  CAPABILITY_APPS,
  CAPABILITY_FLAVOURS,
  FEATURE_KEYS,
  FEATURE_STATES,
  GRANT_KEYS,
  GRANT_STATES,
  type DeviceSetup,
  type FeatureKey,
} from "@familyshield/shared-types";
import { isNotSupported, shownFeatureState } from "./capabilityTable.js";

/**
 * ADR-0034 PR 1a: the capability report, its storage rules, and the one refusal that replaces
 * `locateNowRefusal`.
 *
 * Three things live here because they are the same decision seen from three sides:
 *  * what a device may send ([CapabilitiesSchema], A2: `.strict()`, enum keys and values, 4 KB);
 *  * how it is shown to a parent ([setupFor], decision 3 + A4: the server's clock, never the device's);
 *  * when a command is refused instead of queued ([commandRefusal], decision 3 + A1).
 */

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
  })
  .strict()
  .superRefine((value, ctx) => {
    const bytes = Buffer.byteLength(JSON.stringify(value), "utf8");
    if (bytes > CAPABILITIES_MAX_BYTES) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: `capabilities is ${bytes} bytes; the cap is ${CAPABILITIES_MAX_BYTES}`,
      });
    }
  });

export type Capabilities = z.infer<typeof CapabilitiesSchema>;

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
    return { reportedAt: null, stale: true, features: {}, missing: [] };
  }
  const { client, grants, features } = parsed.data;
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
  const feature = COMMAND_FEATURE[command];
  if (!feature) return null;
  const parsed = CapabilitiesSchema.safeParse(report.capabilities);
  if (!parsed.success) return null;
  const { client, features } = parsed.data;

  if (isNotSupported(client.app, client.flavour, feature)) return { reason: "not_supported" };

  const at = reportedAtMs(report.capabilitiesReportedAt);
  if (at == null || nowMs - at > CAPABILITIES_MAX_AGE_MS) return null;

  const state = shownFeatureState(client.app, client.flavour, feature, features[feature] ?? null);
  if (state === "unavailable") return { reason: `${feature}_unavailable` };
  return null;
}
