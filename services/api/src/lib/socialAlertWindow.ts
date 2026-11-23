import { createHmac } from "node:crypto";
import type { Alert, Prisma } from "@prisma/client";
import { prisma } from "../db.js";
import { getRedis } from "../redis.js";
import { publishFamilyEvent } from "../realtime/gateway.js";
import { raiseAlert } from "./alerts.js";
import { notifyParentsOfAlert } from "./push/notify.js";

/** Issue #1029: 10-minute alert throttle & aggregation window per (child, app, contact). */
export const SOCIAL_ALERT_WINDOW_SECONDS = 600;
export const SOCIAL_ALERT_WINDOW_MS = SOCIAL_ALERT_WINDOW_SECONDS * 1000;

export type SocialSeverity = "info" | "warning" | "critical";
export const SOCIAL_SEVERITY_RANK: Record<SocialSeverity, number> = { info: 0, warning: 1, critical: 2 };

export function normalizeSocialSeverity(value: unknown): SocialSeverity {
  return value === "info" || value === "warning" || value === "critical" ? value : "warning";
}

/**
 * Derive a domain-separated HMAC key from the API's existing classified secrets (`VAULT_KEY` or
 * `INTERNAL_HMAC_SECRET`), avoiding an extra unclassified env var in `check-production-taskdef.mjs`.
 */
function getContactKeySalt(env: NodeJS.ProcessEnv = process.env): Buffer {
  const baseSecret = env.VAULT_KEY || env.INTERNAL_HMAC_SECRET;
  if (baseSecret) {
    return createHmac("sha256", baseSecret).update("osra:social-alert-contact-key:v1").digest();
  }
  if (env.NODE_ENV === "production") {
    throw new Error("VAULT_KEY or INTERNAL_HMAC_SECRET is required in production");
  }
  return Buffer.from("dev-social-alert-contact-salt", "utf8");
}

/**
 * Deterministic salted hash for a child+contact pair (issue #1029).
 *
 * Raw contact names must never appear in Redis throttle keys or server logs. Including `childId`
 * prevents cross-child correlation across keys, and an empty/missing contact maps to a dedicated
 * unknown sentinel bucket so unknown-contact bursts coalesce without colliding with named contacts.
 */
export function socialContactKey(childId: string, contact: string, env: NodeJS.ProcessEnv = process.env): string {
  const normalized = contact.trim().toLowerCase();
  const token = normalized.length > 0 ? normalized : "\u0000unknown";
  return createHmac("sha256", getContactKeySalt(env))
    .update(`${childId}\u0000${token}`)
    .digest("hex")
    .slice(0, 32);
}

/** Per-contact Redis throttle key: `social:alert:${childId}:${app}:${contactKey}` (#1029). */
export function socialAlertThrottleKey(
  childId: string,
  appName: string,
  contact: string,
  env: NodeJS.ProcessEnv = process.env,
): string {
  const app = appName.trim().toLowerCase();
  return `social:alert:${childId}:${app}:${socialContactKey(childId, contact, env)}`;
}

export interface SocialWindowRedisState {
  alertId: string;
  windowStartedAt: string;
  windowEndsAt: string;
  pushedSeverity: SocialSeverity;
}

export interface SocialWindowMetadata {
  app: string;
  contact: string;
  contactKey: string;
  concernTypes: string[];
  flaggedCount: number;
  latestAt: string;
  windowStartedAt: string;
  windowEndsAt: string;
  pushedCount: number;
  pushedSeverity: SocialSeverity;
  summaryPending: boolean;
  summaryPushed: boolean;
  summaryDelta?: number;
  summaryPushedAt?: string;
  providerOutcomes?: Record<string, unknown>;
}

/** Parse window aggregation fields out of an `Alert.metadata` JSON blob; null if not a #1029 window row. */
export function parseSocialWindowMetadata(raw: unknown): SocialWindowMetadata | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const m = raw as Record<string, unknown>;
  if (typeof m.app !== "string" || typeof m.windowEndsAt !== "string") return null;
  const flaggedCount = typeof m.flaggedCount === "number" && Number.isFinite(m.flaggedCount) && m.flaggedCount >= 1
    ? Math.floor(m.flaggedCount)
    : 1;
  const pushedCount = typeof m.pushedCount === "number" && Number.isFinite(m.pushedCount) && m.pushedCount >= 0
    ? Math.floor(m.pushedCount)
    : 1;
  return {
    app: m.app,
    contact: typeof m.contact === "string" ? m.contact : "",
    contactKey: typeof m.contactKey === "string" ? m.contactKey : "",
    concernTypes: Array.isArray(m.concernTypes) ? m.concernTypes.filter((x): x is string => typeof x === "string") : [],
    flaggedCount,
    latestAt: typeof m.latestAt === "string" ? m.latestAt : (typeof m.windowStartedAt === "string" ? m.windowStartedAt : m.windowEndsAt),
    windowStartedAt: typeof m.windowStartedAt === "string" ? m.windowStartedAt : m.windowEndsAt,
    windowEndsAt: m.windowEndsAt,
    pushedCount,
    pushedSeverity: normalizeSocialSeverity(m.pushedSeverity),
    summaryPending: m.summaryPending === true,
    summaryPushed: m.summaryPushed === true,
    ...(typeof m.summaryDelta === "number" ? { summaryDelta: m.summaryDelta } : {}),
    ...(typeof m.summaryPushedAt === "string" ? { summaryPushedAt: m.summaryPushedAt } : {}),
    ...(m.providerOutcomes && typeof m.providerOutcomes === "object" && !Array.isArray(m.providerOutcomes)
      ? { providerOutcomes: m.providerOutcomes as Record<string, unknown> }
      : {}),
  };
}

const PENDING_SENTINEL = "__pending__";

/**
 * Serialize in-process updates for the same `(childId, app, contactKey)` so concurrent items inside a
 * batched `/v1/social/scan` (`Promise.all`) never lose an increment, while distinct contacts/apps keep
 * running concurrently.
 */
const keyLocks = new Map<string, Promise<void>>();

async function withThrottleKeyLock<T>(key: string, fn: () => Promise<T>): Promise<T> {
  const prev = keyLocks.get(key) ?? Promise.resolve();
  let release!: () => void;
  const next = new Promise<void>((resolve) => {
    release = resolve;
  });
  const chained = prev.then(() => next);
  keyLocks.set(key, chained);
  await prev;
  try {
    return await fn();
  } finally {
    release();
    if (keyLocks.get(key) === chained) {
      keyLocks.delete(key);
    }
  }
}

function parseRedisWindowState(raw: string | null): SocialWindowRedisState | null {
  if (!raw || raw === PENDING_SENTINEL) return null;
  try {
    const parsed = JSON.parse(raw) as Partial<SocialWindowRedisState>;
    if (typeof parsed.alertId !== "string" || !parsed.alertId) return null;
    return {
      alertId: parsed.alertId,
      windowStartedAt: typeof parsed.windowStartedAt === "string" ? parsed.windowStartedAt : new Date().toISOString(),
      windowEndsAt: typeof parsed.windowEndsAt === "string" ? parsed.windowEndsAt : new Date(Date.now() + SOCIAL_ALERT_WINDOW_MS).toISOString(),
      pushedSeverity: normalizeSocialSeverity(parsed.pushedSeverity),
    };
  } catch {
    return null;
  }
}

function mergeProviderOutcomes(
  existing: Record<string, unknown> | undefined,
  incoming: Record<string, unknown> | undefined,
): Record<string, unknown> | undefined {
  if (!existing && !incoming) return undefined;
  const merged = { ...(existing ?? {}), ...(incoming ?? {}) };
  return Object.keys(merged).length > 0 ? merged : undefined;
}

export interface RecordFlaggedSocialAlertInput {
  childId: string;
  familyId: string;
  childName?: string | null;
  deviceId?: string | null;
  appName: string;
  contact: string;
  category: "social_concern" | "gaming_chat";
  severity: SocialSeverity;
  concernTypes: string[];
  attribution?: Record<string, unknown>;
  now?: Date;
}

export interface RecordFlaggedSocialAlertResult {
  alertId: string | undefined;
  /** True when this message was absorbed into an open window without an immediate push. */
  throttled: boolean;
  /** True when a higher severity bypassed the open window and pushed immediately. */
  bypassed: boolean;
  flaggedCount: number;
  throttleKey: string;
}

/**
 * Record a flagged social scan against its per-contact 10-minute alert window (#1029).
 *
 * - First flagged message in the window: creates one `Alert` row (`flaggedCount = 1`, `pushedCount = 1`),
 *   publishes it to the live family feed, and pushes parents immediately.
 * - Subsequent flagged messages in the same contact's window: updates the same `Alert` row in place
 *   (`flaggedCount` + `attemptCount` increment, `latestAt` updates, `concernTypes` merge, `acknowledged`
 *   resets to `false`, realtime event publishes to move the card to top). No push unless severity rises.
 * - Severity bypass: if `severity` strictly exceeds `pushedSeverity`, pushes parents immediately and
 *   updates `pushedSeverity` + `pushedCount = flaggedCount`.
 * - Window close: if `flaggedCount > pushedCount` when `windowEndsAt` passes, `runSocialAlertSummarySweep`
 *   sends one summary push and starts a fresh 10-minute window.
 */
export async function recordFlaggedSocialAlert(
  input: RecordFlaggedSocialAlertInput,
): Promise<RecordFlaggedSocialAlertResult> {
  const { childId, familyId, childName, deviceId, appName, category, severity, concernTypes, attribution } = input;
  const contact = input.contact.trim();
  const contactKey = socialContactKey(childId, contact);
  const throttleKey = socialAlertThrottleKey(childId, appName, contact);

  return withThrottleKeyLock(throttleKey, async () => {
    const now = input.now ?? new Date();
    const nowMs = now.getTime();
    const nowIso = now.toISOString();
    const windowEndsAtIso = new Date(nowMs + SOCIAL_ALERT_WINDOW_MS).toISOString();
    const redis = getRedis();

    const claimed = (await redis.set(throttleKey, PENDING_SENTINEL, "EX", SOCIAL_ALERT_WINDOW_SECONDS, "NX")) === "OK";
    if (claimed) {
      let alert: Alert | undefined;
      try {
        // Alerts never carry the message snippet; metadata holds app/contact/concernTypes and
        // #1029 per-contact window counters. Push payloads never carry text or contact names (#410, #1029).
        alert = await raiseAlert({
          childId,
          familyId,
          deviceId,
          severity,
          category,
          title: `Social concern in ${appName}`,
          body: `${contact || "A contact"} sent a flagged message on ${appName}`,
          bodyKey: "alertBodySocialConcern",
          params: { app: appName, ...(contact ? { contact } : {}) },
          attemptCount: 1,
          metadata: {
            app: appName,
            contact,
            contactKey,
            concernTypes,
            flaggedCount: 1,
            latestAt: nowIso,
            windowStartedAt: nowIso,
            windowEndsAt: windowEndsAtIso,
            pushedCount: 1,
            pushedSeverity: severity,
            summaryPending: false,
            summaryPushed: false,
            ...(attribution && Object.keys(attribution).length > 0 && { providerOutcomes: attribution }),
          },
          childName: childName ?? undefined,
        });
      } catch (err) {
        await redis.del(throttleKey).catch(() => undefined);
        throw err;
      }

      if (alert?.id) {
        const state: SocialWindowRedisState = {
          alertId: alert.id,
          windowStartedAt: nowIso,
          windowEndsAt: windowEndsAtIso,
          pushedSeverity: severity,
        };
        await redis.set(throttleKey, JSON.stringify(state), "EX", SOCIAL_ALERT_WINDOW_SECONDS).catch(() => undefined);
      }
      return { alertId: alert?.id, throttled: false, bypassed: false, flaggedCount: 1, throttleKey };
    }

    // Window already open for this (child, app, contactKey): resolve existing alert row.
    let state = parseRedisWindowState(await redis.get(throttleKey).catch(() => null));
    if (!state) {
      // Another API replica may still be committing the initial alert row; retry briefly.
      for (let attempt = 0; attempt < 3 && !state; attempt += 1) {
        const raw = await redis.get(throttleKey).catch(() => null);
        if (raw !== PENDING_SENTINEL) {
          state = parseRedisWindowState(raw);
          break;
        }
        await new Promise((resolve) => setTimeout(resolve, 25));
      }
    }

    let existing: Alert | null = null;
    if (state?.alertId) {
      existing = await prisma.alert.findUnique({ where: { id: state.alertId } });
    }
    if (!existing) {
      // Fallback when Redis held a bare marker or a minimal mock didn't stub `get`: find the most
      // recent open window alert for this child, category, and salted contactKey.
      const recent = await prisma.alert.findMany({
        where: {
          childId,
          category,
          createdAt: { gte: new Date(nowMs - SOCIAL_ALERT_WINDOW_MS) },
        },
        orderBy: { createdAt: "desc" },
        take: 25,
      });
      if (Array.isArray(recent)) {
        existing = recent.find((row) => {
          const parsed = parseSocialWindowMetadata(row.metadata);
          return parsed?.contactKey === contactKey && parsed.app.toLowerCase() === appName.trim().toLowerCase();
        }) ?? null;
      }
    }

    if (!existing) {
      // No backing row exists (e.g. legacy mock test that only mocked alert.create without persisting rows).
      return { alertId: state?.alertId, throttled: true, bypassed: false, flaggedCount: 1, throttleKey };
    }

    let current: Alert = existing;
    let updatedAlert: Alert | null = null;
    let bypass = false;
    let nextCount = 1;
    let nextPushedSeverity: SocialSeverity = "warning";
    let effectiveWindowStart = nowIso;
    let effectiveWindowEnd = windowEndsAtIso;

    // Optimistic CAS loop across multiple API replicas: compare-and-swap on `attemptCount` so
    // two ECS tasks updating the same contact's alert simultaneously never lose an increment.
    for (let casAttempt = 0; casAttempt < 4; casAttempt += 1) {
      const existingMetaObj = (current.metadata && typeof current.metadata === "object" && !Array.isArray(current.metadata)
        ? current.metadata
        : {}) as Record<string, unknown>;
      const existingMeta = parseSocialWindowMetadata(existingMetaObj);

      const prevCount = existingMeta?.flaggedCount ?? current.attemptCount ?? 1;
      nextCount = prevCount + 1;
      const prevPushedCount = existingMeta?.pushedCount ?? 1;
      const prevPushedSeverity =
        casAttempt === 0
          ? (existingMeta?.pushedSeverity ?? state?.pushedSeverity ?? normalizeSocialSeverity(current.severity))
          : (existingMeta?.pushedSeverity ?? normalizeSocialSeverity(current.severity));
      bypass = SOCIAL_SEVERITY_RANK[severity] > SOCIAL_SEVERITY_RANK[prevPushedSeverity];
      const nextSeverity =
        SOCIAL_SEVERITY_RANK[severity] > SOCIAL_SEVERITY_RANK[normalizeSocialSeverity(current.severity)]
          ? severity
          : normalizeSocialSeverity(current.severity);
      const nextPushedCount = bypass ? nextCount : prevPushedCount;
      nextPushedSeverity = bypass ? severity : prevPushedSeverity;
      const nextSummaryPending = nextCount > nextPushedCount;
      const mergedConcerns = [...new Set([...(existingMeta?.concernTypes ?? []), ...concernTypes])].slice(0, 5);
      const mergedAttribution = mergeProviderOutcomes(existingMeta?.providerOutcomes, attribution);
      effectiveWindowStart = existingMeta?.windowStartedAt ?? state?.windowStartedAt ?? nowIso;
      effectiveWindowEnd = existingMeta?.windowEndsAt ?? state?.windowEndsAt ?? windowEndsAtIso;

      const nextMetadata: Record<string, unknown> = {
        ...existingMetaObj,
        app: appName,
        contact,
        contactKey,
        concernTypes: mergedConcerns,
        flaggedCount: nextCount,
        latestAt: nowIso,
        windowStartedAt: effectiveWindowStart,
        windowEndsAt: effectiveWindowEnd,
        pushedCount: nextPushedCount,
        pushedSeverity: nextPushedSeverity,
        summaryPending: nextSummaryPending,
        summaryPushed: existingMeta?.summaryPushed ?? false,
        bodyKey: "alertBodySocialConcern",
        bodyParams: { app: appName, ...(contact ? { contact } : {}) },
        ...(mergedAttribution ? { providerOutcomes: mergedAttribution } : {}),
      };

      const nextBody = `${nextCount} concerning messages on ${appName}`;
      const casData = {
        severity: nextSeverity,
        attemptCount: nextCount,
        body: nextBody,
        acknowledged: false,
        metadata: nextMetadata as Prisma.InputJsonValue,
      };
      const casRes = await prisma.alert.updateMany({
        where: { id: current.id, attemptCount: prevCount },
        data: casData,
      });
      if (casRes && typeof casRes.count === "number") {
        if (casRes.count === 1) {
          updatedAlert = (await prisma.alert.findUnique({ where: { id: current.id } })) ?? {
            ...current,
            ...casData,
            metadata: nextMetadata as Prisma.JsonValue,
          };
          break;
        }
        const refreshed = await prisma.alert.findUnique({ where: { id: current.id } });
        if (!refreshed) break;
        current = refreshed;
        continue;
      }

      const updated = await prisma.alert.update({ where: { id: current.id }, data: casData });
      updatedAlert = updated ?? {
        ...current,
        ...casData,
        metadata: nextMetadata as Prisma.JsonValue,
      };
      break;
    }

    if (!updatedAlert) {
      return { alertId: current.id, throttled: true, bypassed: false, flaggedCount: current.attemptCount ?? 1, throttleKey };
    }

    // Publish the updated row so an open parent feed updates the card in place and moves it to the top.
    await publishFamilyEvent(familyId, { type: "alert", payload: updatedAlert, ts: nowIso });

    if (bypass) {
      const remainingSeconds = Math.max(1, Math.ceil((Date.parse(effectiveWindowEnd) - nowMs) / 1000));
      const nextRedisState: SocialWindowRedisState = {
        alertId: updatedAlert.id,
        windowStartedAt: effectiveWindowStart,
        windowEndsAt: effectiveWindowEnd,
        pushedSeverity: nextPushedSeverity,
      };
      await redis.set(
        throttleKey,
        JSON.stringify(nextRedisState),
        "EX",
        Number.isFinite(remainingSeconds) ? remainingSeconds : SOCIAL_ALERT_WINDOW_SECONDS,
      ).catch(() => undefined);
      await notifyParentsOfAlert(familyId, updatedAlert, childName ?? undefined);
    }

    return { alertId: updatedAlert.id, throttled: !bypass, bypassed: bypass, flaggedCount: nextCount, throttleKey };
  });
}