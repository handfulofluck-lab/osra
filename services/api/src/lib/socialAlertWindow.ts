import { createHmac, randomUUID } from "node:crypto";
import type { Alert, Prisma } from "@prisma/client";
import { prisma } from "../db.js";
import { getRedis } from "../redis.js";
import { publishFamilyEvent } from "../realtime/gateway.js";
import { raiseAlert } from "./alerts.js";
import { notifyParentsOfAlert } from "./push/notify.js";

/** Issue #1029: 10-minute alert throttle & aggregation window per (child, app, contact). */
export const SOCIAL_ALERT_WINDOW_SECONDS = 600;
export const SOCIAL_ALERT_WINDOW_MS = SOCIAL_ALERT_WINDOW_SECONDS * 1000;

/** Default budget a concurrent replica waits for `__pending__` before handing off to the deferred queue. */
export const DEFAULT_PENDING_WAIT_MS = 5_000;

/**
 * Issue #1061: staging-only switch — one push per flagged message instead of the 10-minute window.
 *
 * Karim asked to see how the own model judges each message during the 24 Nov test, so a message that
 * is folded into a window would otherwise be invisible until the summary. Card aggregation is unchanged:
 * the Alerts list still shows one card per contact with a running count; only the pushes multiply.
 * Production keeps the window: `scripts/check-production-taskdef.mjs` refuses this name outright.
 */
export function pushEveryMessageEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.SOCIAL_ALERT_PUSH_EVERY_MESSAGE === "true";
}

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

/** Per-window deferred observation queue key bound to the originating claimId (#1029, Codex 7119167276). */
export function socialAlertDeferredKey(throttleKey: string, claimId: string): string {
  return `${throttleKey}:deferred:${claimId}`;
}

export interface SocialWindowRedisState {
  alertId: string;
  claimId?: string;
  windowStartedAt: string;
  windowEndsAt: string;
  pushedSeverity: SocialSeverity;
}

export interface SocialWindowMetadata {
  app: string;
  contact: string;
  contactKey: string;
  windowClaimId?: string;
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
    ...(typeof m.windowClaimId === "string" && m.windowClaimId.length > 0 ? { windowClaimId: m.windowClaimId } : {}),
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

const PENDING_PREFIX = "__pending__:";

function parsePendingClaimId(raw: string | null): string | null {
  if (!raw || !raw.startsWith(PENDING_PREFIX)) return null;
  const id = raw.slice(PENDING_PREFIX.length);
  return id.length > 0 ? id : null;
}

/**
 * Atomic handoff when a second replica waits out the pending budget while replica 1 is still
 * inserting the initial alert row (Redis 5.0.14 compatible; Codex #1033 review 7117292252).
 *
 * - If `KEYS[1]` still holds `__pending__`: appends the structured observation (no message text or
 *   contact name) onto `KEYS[2]` (`${throttleKey}:deferred`) and returns `'DEFERRED'`.
 * - Otherwise returns the current `KEYS[1]` value (the committed window JSON or `''` if released)
 *   without touching `KEYS[2]`, so replica 2 updates the row directly or re-claims.
 */
export const SOCIAL_PENDING_DEFER_SCRIPT = `
local cur = redis.call('GET', KEYS[1])
if cur == ARGV[1] then
  redis.call('RPUSH', KEYS[2], ARGV[2])
  redis.call('EXPIRE', KEYS[2], tonumber(ARGV[3]))
  return 'DEFERRED'
end
return cur or ''
`;

/**
 * Atomic publish-and-drain called by the creator replica right after `raiseAlert` commits
 * (Redis 5.0.14 compatible). Serializes with `SOCIAL_PENDING_DEFER_SCRIPT` on Redis's single thread:
 * every concurrent observation either lands in `KEYS[2]` before publish (and is returned here for
 * immediate folding) or sees the published JSON in `KEYS[1]` and updates the row directly via CAS.
 */
export const SOCIAL_PENDING_PUBLISH_AND_PEEK_SCRIPT = `
redis.call('SET', KEYS[1], ARGV[1], 'EX', tonumber(ARGV[2]))
return redis.call('LRANGE', KEYS[2], 0, -1)
`;

/**
 * Trim the exact prefix of deferred entries whose database update has already committed
 * (Redis 5.0.14 compatible; Codex #1033 review 7118711880). Leaves concurrently appended items intact.
 */
export const SOCIAL_PENDING_ACK_SCRIPT = `
local n = tonumber(ARGV[1])
if n and n > 0 then
  redis.call('LTRIM', KEYS[1], n, -1)
end
return redis.call('LLEN', KEYS[1])
`;

/** Release a `__pending__` claim only if it is still ours (avoids deleting another replica's state). */
export const SOCIAL_PENDING_RELEASE_SCRIPT = `
if redis.call('GET', KEYS[1]) == ARGV[1] then
  return redis.call('DEL', KEYS[1])
end
return 0
`;

export interface DeferredSocialObservation {
  /** Opaque per-observation id for idempotent replay across post-commit crashes (zero PII). */
  id?: string;
  /** Originating window claim id binding this entry strictly to one alert window. */
  claimId?: string;
  severity: SocialSeverity;
  concernTypes: string[];
  observedAt: string;
  attribution?: Record<string, unknown>;
}

function parseDeferredObservation(raw: unknown): DeferredSocialObservation | null {
  if (typeof raw !== "string") return null;
  try {
    const parsed = JSON.parse(raw) as Partial<DeferredSocialObservation>;
    if (typeof parsed.observedAt !== "string") return null;
    return {
      ...(typeof parsed.id === "string" && parsed.id.length > 0 ? { id: parsed.id } : {}),
      ...(typeof parsed.claimId === "string" && parsed.claimId.length > 0 ? { claimId: parsed.claimId } : {}),
      severity: normalizeSocialSeverity(parsed.severity),
      concernTypes: Array.isArray(parsed.concernTypes)
        ? parsed.concernTypes.filter((x): x is string => typeof x === "string")
        : [],
      observedAt: parsed.observedAt,
      ...(parsed.attribution && typeof parsed.attribution === "object" && !Array.isArray(parsed.attribution)
        ? { attribution: parsed.attribution as Record<string, unknown> }
        : {}),
    };
  } catch {
    return null;
  }
}

async function ackDeferredEntries(redis: ReturnType<typeof getRedis>, deferredKey: string, count: number): Promise<void> {
  if (count <= 0) return;
  await redis.eval(SOCIAL_PENDING_ACK_SCRIPT, 1, deferredKey, String(count)).catch(() => undefined);
}

async function peekDeferredEntries(
  redis: ReturnType<typeof getRedis>,
  deferredKey: string,
): Promise<{ rawCount: number; observations: DeferredSocialObservation[] }> {
  const r = redis as unknown as { lrange?: (k: string, s: number, e: number) => Promise<string[]> };
  if (typeof r.lrange !== "function") return { rawCount: 0, observations: [] };
  const rawList = await r.lrange(deferredKey, 0, -1).catch(() => null);
  if (!Array.isArray(rawList) || rawList.length === 0) return { rawCount: 0, observations: [] };
  return {
    rawCount: rawList.length,
    observations: rawList.map(parseDeferredObservation).filter((x): x is DeferredSocialObservation => x !== null),
  };
}

const PENDING_BACKOFF_STEPS_MS = [15, 25, 40, 60, 100, 150, 200] as const;

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
  if (!raw || raw === "__pending__" || raw.startsWith(PENDING_PREFIX)) return null;
  try {
    const parsed = JSON.parse(raw) as Partial<SocialWindowRedisState>;
    if (typeof parsed.alertId !== "string" || !parsed.alertId) return null;
    return {
      alertId: parsed.alertId,
      ...(typeof parsed.claimId === "string" && parsed.claimId.length > 0 ? { claimId: parsed.claimId } : {}),
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
  /** Optional override for how long a concurrent replica polls `__pending__` before deferring via Redis. */
  pendingWaitMs?: number;
}

export interface RecordFlaggedSocialAlertResult {
  alertId: string | undefined;
  /** True when this message was absorbed into an open window without an immediate push. */
  throttled: boolean;
  /** True when a higher severity bypassed the open window and pushed immediately. */
  bypassed: boolean;
  /** True when CAS retries exhausted without committing; caller/sweep must retry and deferred entries stay queued. */
  retryable?: boolean;
  flaggedCount: number;
  throttleKey: string;
}

interface ApplyContext {
  familyId: string;
  childName?: string | null;
  appName: string;
  contact: string;
  contactKey: string;
  throttleKey: string;
  nowMs: number;
  nowIso: string;
  windowEndsAtIso: string;
  redis: ReturnType<typeof getRedis>;
  /** #1061: push after every applied observation instead of waiting for the window summary. */
  pushEveryMessage?: boolean;
}

async function applyObservationsToAlert(
  existing: Alert,
  state: SocialWindowRedisState | null,
  observations: DeferredSocialObservation[],
  ctx: ApplyContext,
): Promise<RecordFlaggedSocialAlertResult & { updatedAlert: Alert | null; committed: boolean }> {
  let current: Alert = existing;
  let updatedAlert: Alert | null = null;
  let bypass = false;
  let nextCount = existing.attemptCount ?? 1;
  let nextPushedSeverity: SocialSeverity = "warning";
  let effectiveWindowStart = ctx.nowIso;
  let effectiveWindowEnd = ctx.windowEndsAtIso;
  let latestObservedAt = ctx.nowIso;

  for (let casAttempt = 0; casAttempt < 6; casAttempt += 1) {
    const existingMetaObj = (current.metadata && typeof current.metadata === "object" && !Array.isArray(current.metadata)
      ? current.metadata
      : {}) as Record<string, unknown>;
    const existingMeta = parseSocialWindowMetadata(existingMetaObj);
    const prevAppliedIds = Array.isArray(existingMetaObj.appliedDeferredIds)
      ? existingMetaObj.appliedDeferredIds.filter((x): x is string => typeof x === "string")
      : [];
    const appliedSet = new Set(prevAppliedIds);
    const batchSeen = new Set<string>();
    const unapplied: DeferredSocialObservation[] = [];
    for (const obs of observations) {
      if (obs.id) {
        if (appliedSet.has(obs.id) || batchSeen.has(obs.id)) continue;
        batchSeen.add(obs.id);
      }
      unapplied.push(obs);
    }

    const prevCount = existingMeta?.flaggedCount ?? current.attemptCount ?? 1;
    if (unapplied.length === 0) {
      return {
        alertId: current.id,
        throttled: true,
        bypassed: false,
        retryable: false,
        flaggedCount: prevCount,
        throttleKey: ctx.throttleKey,
        updatedAlert: current,
        committed: true,
      };
    }

    let highestIncomingSeverity: SocialSeverity = "info";
    latestObservedAt = ctx.nowIso;
    const allIncomingConcerns: string[] = [];
    let combinedAttribution: Record<string, unknown> | undefined;
    for (const obs of unapplied) {
      if (SOCIAL_SEVERITY_RANK[obs.severity] > SOCIAL_SEVERITY_RANK[highestIncomingSeverity]) {
        highestIncomingSeverity = obs.severity;
      }
      if (obs.observedAt > latestObservedAt) {
        latestObservedAt = obs.observedAt;
      }
      allIncomingConcerns.push(...obs.concernTypes);
      combinedAttribution = mergeProviderOutcomes(combinedAttribution, obs.attribution);
    }
    const nextAppliedIds = [...prevAppliedIds, ...unapplied.map((o) => o.id).filter((x): x is string => Boolean(x))].slice(-100);
    nextCount = prevCount + unapplied.length;
    const prevPushedCount = existingMeta?.pushedCount ?? 1;
    const prevPushedSeverity =
      casAttempt === 0
        ? (existingMeta?.pushedSeverity ?? state?.pushedSeverity ?? normalizeSocialSeverity(current.severity))
        : (existingMeta?.pushedSeverity ?? normalizeSocialSeverity(current.severity));
    bypass = SOCIAL_SEVERITY_RANK[highestIncomingSeverity] > SOCIAL_SEVERITY_RANK[prevPushedSeverity];
    const nextSeverity =
      SOCIAL_SEVERITY_RANK[highestIncomingSeverity] > SOCIAL_SEVERITY_RANK[normalizeSocialSeverity(current.severity)]
        ? highestIncomingSeverity
        : normalizeSocialSeverity(current.severity);
    const pushEvery = ctx.pushEveryMessage === true;
    const nextPushedCount = bypass || pushEvery ? nextCount : prevPushedCount;
    nextPushedSeverity = bypass || pushEvery ? highestIncomingSeverity : prevPushedSeverity;
    const nextSummaryPending = nextCount > nextPushedCount;
    const mergedConcerns = [...new Set([...(existingMeta?.concernTypes ?? []), ...allIncomingConcerns])].slice(0, 5);
    const mergedAttribution = mergeProviderOutcomes(existingMeta?.providerOutcomes, combinedAttribution);
    effectiveWindowStart = existingMeta?.windowStartedAt ?? state?.windowStartedAt ?? ctx.nowIso;
    effectiveWindowEnd = existingMeta?.windowEndsAt ?? state?.windowEndsAt ?? ctx.windowEndsAtIso;
    const effectiveLatestAt =
      existingMeta?.latestAt && existingMeta.latestAt > latestObservedAt ? existingMeta.latestAt : latestObservedAt;

    const nextMetadata: Record<string, unknown> = {
      ...existingMetaObj,
      app: ctx.appName,
      contact: ctx.contact,
      contactKey: ctx.contactKey,
      concernTypes: mergedConcerns,
      flaggedCount: nextCount,
      latestAt: effectiveLatestAt,
      windowStartedAt: effectiveWindowStart,
      windowEndsAt: effectiveWindowEnd,
      pushedCount: nextPushedCount,
      pushedSeverity: nextPushedSeverity,
      summaryPending: nextSummaryPending,
      summaryPushed: existingMeta?.summaryPushed ?? false,
      bodyKey: "alertBodySocialConcern",
      bodyParams: { app: ctx.appName, ...(ctx.contact ? { contact: ctx.contact } : {}) },
      ...(nextAppliedIds.length > 0 ? { appliedDeferredIds: nextAppliedIds } : {}),
      ...(mergedAttribution ? { providerOutcomes: mergedAttribution } : {}),
    };

    const nextBody = `${nextCount} concerning messages on ${ctx.appName}`;
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
    // All CAS attempts conflicted: do NOT acknowledge deferred entries; return an explicit retryable outcome.
    return {
      alertId: current.id,
      throttled: true,
      bypassed: false,
      retryable: true,
      flaggedCount: current.attemptCount ?? 1,
      throttleKey: ctx.throttleKey,
      updatedAlert: null,
      committed: false,
    };
  }

  await publishFamilyEvent(ctx.familyId, { type: "alert", payload: updatedAlert, ts: latestObservedAt });

  if (bypass) {
    const remainingSeconds = Math.max(1, Math.ceil((Date.parse(effectiveWindowEnd) - ctx.nowMs) / 1000));
    const updatedMeta = parseSocialWindowMetadata(updatedAlert.metadata);
    const nextRedisState: SocialWindowRedisState = {
      alertId: updatedAlert.id,
      ...(updatedMeta?.windowClaimId ? { claimId: updatedMeta.windowClaimId } : state?.claimId ? { claimId: state.claimId } : {}),
      windowStartedAt: effectiveWindowStart,
      windowEndsAt: effectiveWindowEnd,
      pushedSeverity: nextPushedSeverity,
    };
    await ctx.redis
      .set(
        ctx.throttleKey,
        JSON.stringify(nextRedisState),
        "EX",
        Number.isFinite(remainingSeconds) ? remainingSeconds : SOCIAL_ALERT_WINDOW_SECONDS,
      )
      .catch(() => undefined);
    await notifyParentsOfAlert(ctx.familyId, updatedAlert, ctx.childName ?? undefined);
  }

  return {
    alertId: updatedAlert.id,
    throttled: !bypass,
    bypassed: bypass,
    retryable: false,
    flaggedCount: nextCount,
    throttleKey: ctx.throttleKey,
    updatedAlert,
    committed: true,
  };
}

/**
 * Idempotently replay any deferred observations still in `${throttleKey}:deferred` onto `alert`,
 * trimming them from Redis **only after** the database update commits (#1029).
 */
export async function replayDeferredSocialObservations(
  alert: Alert,
  opts: { familyId: string; childName?: string | null; now?: Date },
): Promise<Alert> {
  const meta = parseSocialWindowMetadata(alert.metadata);
  if (!meta?.contactKey || !meta.windowClaimId) return alert;
  const redis = getRedis();
  const throttleKey = `social:alert:${alert.childId}:${meta.app.trim().toLowerCase()}:${meta.contactKey}`;
  const deferredKey = socialAlertDeferredKey(throttleKey, meta.windowClaimId);
  const { rawCount, observations } = await peekDeferredEntries(redis, deferredKey);
  if (rawCount === 0) return alert;
  const matching = observations.filter((o) => !o.claimId || o.claimId === meta.windowClaimId);
  if (matching.length === 0) {
    if (observations.length === 0) {
      await ackDeferredEntries(redis, deferredKey, rawCount);
    }
    return alert;
  }
  const now = opts.now ?? new Date();
  const result = await applyObservationsToAlert(alert, null, matching, {
    familyId: opts.familyId,
    childName: opts.childName,
    appName: meta.app,
    contact: meta.contact,
    contactKey: meta.contactKey,
    throttleKey,
    nowMs: now.getTime(),
    nowIso: now.toISOString(),
    windowEndsAtIso: meta.windowEndsAt,
    redis,
  });
  if (result.committed) {
    await ackDeferredEntries(redis, deferredKey, rawCount);
  }
  return result.updatedAlert ?? alert;
}

/**
 * Record a flagged social scan against its per-contact 10-minute alert window (#1029).
 *
 * - First flagged message in the window: creates one `Alert` row (`flaggedCount = 1`, `pushedCount = 1`),
 *   publishes it to the live family feed, and pushes parents immediately.
 * - Subsequent flagged messages in the same contact's window: updates the same `Alert` row in place
 *   (`flaggedCount` + `attemptCount` increment, `latestAt` updates, `concernTypes` merge, `acknowledged`
 *   resets to `false`, realtime event publishes to move the card to top). No push unless severity rises.
 * - Multi-replica cold start: if replica 2 arrives while replica 1's initial insert is still in flight
 *   (`__pending__`), replica 2 waits with backoff up to `pendingWaitMs` and, if still pending, atomically
 *   hands off its observation to `${throttleKey}:deferred` via Lua so replica 1 folds it immediately on
 *   publish — zero lost increments regardless of insert latency.
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
  const pushEvery = pushEveryMessageEnabled();
  const waitBudgetMs =
    typeof input.pendingWaitMs === "number" && Number.isFinite(input.pendingWaitMs) && input.pendingWaitMs >= 0
      ? input.pendingWaitMs
      : DEFAULT_PENDING_WAIT_MS;

  return withThrottleKeyLock(throttleKey, async () => {
    const now = input.now ?? new Date();
    const nowMs = now.getTime();
    const nowIso = now.toISOString();
    const windowEndsAtIso = new Date(nowMs + SOCIAL_ALERT_WINDOW_MS).toISOString();
    const redis = getRedis();
    const observation: DeferredSocialObservation = {
      id: randomUUID(),
      severity,
      concernTypes,
      observedAt: nowIso,
      ...(attribution && Object.keys(attribution).length > 0 ? { attribution } : {}),
    };
    const applyCtx: ApplyContext = {
      familyId,
      childName,
      appName,
      contact,
      contactKey,
      throttleKey,
      nowMs,
      nowIso,
      windowEndsAtIso,
      redis,
      pushEveryMessage: pushEvery,
    };

    for (let claimPass = 0; claimPass < 2; claimPass += 1) {
      const claimId = randomUUID();
      const pendingToken = `${PENDING_PREFIX}${claimId}`;
      const claimed = (await redis.set(throttleKey, pendingToken, "EX", SOCIAL_ALERT_WINDOW_SECONDS, "NX")) === "OK";
      if (claimed) {
        const ownDeferredKey = socialAlertDeferredKey(throttleKey, claimId);
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
              windowClaimId: claimId,
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
          const released = await redis
            .eval(SOCIAL_PENDING_RELEASE_SCRIPT, 1, throttleKey, pendingToken)
            .catch(() => null);
          if (released !== 0 && released !== 1) {
            await redis.del(throttleKey).catch(() => undefined);
          }
          throw err;
        }

        if (alert?.id) {
          const state: SocialWindowRedisState = {
            alertId: alert.id,
            claimId,
            windowStartedAt: nowIso,
            windowEndsAt: windowEndsAtIso,
            pushedSeverity: severity,
          };
          const payload = JSON.stringify(state);
          const peekedRaw = await redis
            .eval(
              SOCIAL_PENDING_PUBLISH_AND_PEEK_SCRIPT,
              2,
              throttleKey,
              ownDeferredKey,
              payload,
              String(SOCIAL_ALERT_WINDOW_SECONDS),
            )
            .catch(() => null);
          let deferred: DeferredSocialObservation[] = [];
          let peekedRawCount = 0;
          if (Array.isArray(peekedRaw)) {
            peekedRawCount = peekedRaw.length;
            deferred = peekedRaw
              .map(parseDeferredObservation)
              .filter((x): x is DeferredSocialObservation => x !== null && (!x.claimId || x.claimId === claimId));
          } else {
            await redis.set(throttleKey, payload, "EX", SOCIAL_ALERT_WINDOW_SECONDS).catch(() => undefined);
          }

          if (deferred.length > 0) {
            const folded = await applyObservationsToAlert(alert, state, deferred, applyCtx);
            // Acknowledge ONLY after DB commit or confirmed idempotent replay (Codex 7119141081).
            if (folded.committed) {
              await ackDeferredEntries(redis, ownDeferredKey, peekedRawCount);
            }
            return {
              alertId: folded.alertId,
              throttled: false,
              bypassed: folded.bypassed,
              ...(folded.retryable ? { retryable: true } : {}),
              flaggedCount: folded.flaggedCount,
              throttleKey,
            };
          } else if (peekedRawCount > 0) {
            await ackDeferredEntries(redis, ownDeferredKey, peekedRawCount);
          }
        }
        return { alertId: alert?.id, throttled: false, bypassed: false, flaggedCount: 1, throttleKey };
      }

      // Window already open (or initial insert still in flight on another replica).
      let raw = await redis.get(throttleKey).catch(() => null);
      let state = parseRedisWindowState(raw);
      let shouldRetryClaim = false;

      if (parsePendingClaimId(raw) !== null) {
        let waitedMs = 0;
        let stepIdx = 0;
        while (parsePendingClaimId(raw) !== null && waitedMs < waitBudgetMs) {
          const delay = Math.min(
            PENDING_BACKOFF_STEPS_MS[Math.min(stepIdx, PENDING_BACKOFF_STEPS_MS.length - 1)]!,
            waitBudgetMs - waitedMs,
          );
          stepIdx += 1;
          await new Promise((resolve) => setTimeout(resolve, delay));
          waitedMs += delay;
          raw = await redis.get(throttleKey).catch(() => null);
          if (raw === null) {
            shouldRetryClaim = true;
            break;
          }
          if (parsePendingClaimId(raw) === null) {
            state = parseRedisWindowState(raw);
            break;
          }
        }

        if (shouldRetryClaim && claimPass === 0) {
          continue;
        }

        // Still pending after wait budget: bind handoff strictly to the active claimId's queue.
        const targetClaimId = parsePendingClaimId(raw);
        if (targetClaimId !== null && raw !== null) {
          const targetDeferredKey = socialAlertDeferredKey(throttleKey, targetClaimId);
          const boundObservation: DeferredSocialObservation = { ...observation, claimId: targetClaimId };
          const deferRes = await redis
            .eval(
              SOCIAL_PENDING_DEFER_SCRIPT,
              2,
              throttleKey,
              targetDeferredKey,
              raw,
              JSON.stringify(boundObservation),
              String(SOCIAL_ALERT_WINDOW_SECONDS),
            )
            .catch(() => null);
          if (deferRes === "DEFERRED") {
            return { alertId: undefined, throttled: true, bypassed: false, flaggedCount: 1, throttleKey };
          }
          if (deferRes === "" && claimPass === 0) {
            continue;
          }
          if (typeof deferRes === "string" && deferRes.length > 0) {
            if (parsePendingClaimId(deferRes) !== null && claimPass === 0) {
              continue;
            }
            state = parseRedisWindowState(deferRes);
          }
        }
      }

      let existing: Alert | null = null;
      if (state?.alertId) {
        existing = await prisma.alert.findUnique({ where: { id: state.alertId } });
      }
      if (!existing) {
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
        return { alertId: state?.alertId, throttled: true, bypassed: false, flaggedCount: 1, throttleKey };
      }

      const existingMeta = parseSocialWindowMetadata(existing.metadata);
      const existingClaimId = existingMeta?.windowClaimId ?? state?.claimId;
      const windowDeferredKey = existingClaimId ? socialAlertDeferredKey(throttleKey, existingClaimId) : null;
      const pending = windowDeferredKey
        ? await peekDeferredEntries(redis, windowDeferredKey)
        : { rawCount: 0, observations: [] };
      const matchingPending = existingClaimId
        ? pending.observations.filter((o) => !o.claimId || o.claimId === existingClaimId)
        : [];
      const batch = matchingPending.length > 0 ? [...matchingPending, observation] : [observation];
      const applied = await applyObservationsToAlert(existing, state, batch, applyCtx);
      // Issue #1061: with the switch on, every applied observation is pushed now; the summary stays off because
      // applyObservationsToAlert counts it as already pushed.
      // `bypass` already pushed inside applyObservationsToAlert, so a severity step-up must not push twice.
      if (pushEvery && applied.committed && applied.updatedAlert && !applied.bypassed) {
        await notifyParentsOfAlert(familyId, applied.updatedAlert, childName ?? undefined);
      }
      if (applied.committed && windowDeferredKey && pending.rawCount > 0) {
        await ackDeferredEntries(redis, windowDeferredKey, pending.rawCount);
      }
      return {
        alertId: applied.alertId,
        throttled: applied.throttled,
        bypassed: applied.bypassed,
        ...(applied.retryable ? { retryable: true } : {}),
        flaggedCount: applied.flaggedCount,
        throttleKey: applied.throttleKey,
      };
    }

    return { alertId: undefined, throttled: true, bypassed: false, retryable: true, flaggedCount: 1, throttleKey };
  });
}
