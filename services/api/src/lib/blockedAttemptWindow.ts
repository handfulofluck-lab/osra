import { createHmac } from "node:crypto";
import type { Alert, Prisma } from "@prisma/client";
import { prisma } from "../db.js";
import { getRedis } from "../redis.js";
import { publishFamilyEvent } from "../realtime/gateway.js";
import { raiseAlertOnce } from "./alerts.js";
import { notifyParentsOfAlert } from "./push/notify.js";
import { hostOf } from "./siteNames.js";
import { nextPushDelivery, socialAlertWindowMs, socialAlertWindowSeconds, takeSocialPushBudget } from "./socialAlertWindow.js";

/**
 * #1222 (Karim, 26 Nov 22:56 UAE): blocked-site and blocked-app attempts follow the #1139 rule already
 * live for flagged messages. The first N attempts (`SOCIAL_ALERT_FIRST_PUSHES`, default 3) each push; after
 * that they are grouped and summarised every window (`SOCIAL_ALERT_SUMMARY_MINUTES`, default 10).
 *
 * One row covers one run of attempts: the row stays open while attempts keep arriving less than one window
 * apart, on the same family-local day. A quiet window or a new day starts a new row. This replaces the
 * producer's per-UTC-day key, under which every attempt of a day folded silently into the first one (#227),
 * and the day rolled over at 03:00 in Doha. The row carries the count and the latest time (`latestAt`, which
 * the parent app already sorts and labels by), so the folded row moves to the top.
 */
export type BlockedKind = "web" | "app";

export const BLOCKED_GROUP_CATEGORIES = ["web_threat", "app_blocked"] as const;

export function blockedKindFor(category: string): BlockedKind | null {
  if (category === "web_threat") return "web";
  if (category === "app_blocked") return "app";
  return null;
}

/** The (child, kind) push budget shares the #1139 slots under its own app name. */
export function blockedBudgetName(kind: BlockedKind): string {
  return `blocked-${kind}`;
}

/**
 * What a run is about. With site names off every blocked site is one subject (the parent sees a count with
 * no host); with names on, one host. An app is its package. Anything unusable becomes the empty subject, so
 * an attempt is never dropped for a missing field.
 */
export function blockedSubject(kind: BlockedKind, metadata: Record<string, unknown>, siteNames: boolean): string {
  if (kind === "web") {
    if (!siteNames) return "";
    const raw = typeof metadata.domain === "string" ? metadata.domain : "";
    return hostOf(raw).slice(0, 120);
  }
  const pkg = typeof metadata.packageId === "string" ? metadata.packageId.trim().toLowerCase() : "";
  return /^[a-z0-9_.]{1,150}$/.test(pkg) ? pkg : "";
}

/** `yyyy-mm-dd` in the family's zone; UTC when the zone is missing or not one Intl knows. */
export function familyLocalDay(at: Date, timeZone: string | null | undefined): string {
  const fmt = (zone: string) =>
    new Intl.DateTimeFormat("en-CA", { timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit" }).format(at);
  try {
    return fmt(timeZone || "UTC");
  } catch {
    return fmt("UTC");
  }
}

export function blockedGroupPrefix(kind: BlockedKind, subject: string, day: string): string {
  return `grp:${kind}:${subject}:${day}:`;
}

/**
 * One accepted attempt in a group (#1222, lead 00:35 UAE: "each attempt still listed"). Newest first, capped at
 * BLOCKED_ATTEMPTS_CAP; the full total stays in alert.attemptCount. `site` only when site names are on; `app` is the
 * phone's app label, else the package id. Contract for the parent app: #1228 comment 7203909801.
 */
export interface BlockedAttemptEntry {
  at: string;
  site?: string;
  app?: string;
}

export const BLOCKED_ATTEMPTS_CAP = 50;

export interface BlockedGroupState {
  kind: BlockedKind;
  day: string;
  firstAt: string;
  latestAt: string;
  pushedCount: number;
  lastPushAt?: string;
  summaryPending: boolean;
  summaryDueAt?: string;
  summaryPushedAt?: string;
  attempts?: BlockedAttemptEntry[];
}

function parseAttempts(raw: unknown): BlockedAttemptEntry[] | undefined {
  if (!Array.isArray(raw)) return undefined;
  const out: BlockedAttemptEntry[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object" || Array.isArray(item)) continue;
    const e = item as Record<string, unknown>;
    if (typeof e.at !== "string" || !Number.isFinite(Date.parse(e.at))) continue;
    out.push({
      at: e.at,
      ...(typeof e.site === "string" && e.site ? { site: e.site } : {}),
      ...(typeof e.app === "string" && e.app ? { app: e.app } : {}),
    });
  }
  return out;
}

/** Insert one entry by time (newest first) and keep the newest BLOCKED_ATTEMPTS_CAP. */
export function withAttempt(list: BlockedAttemptEntry[] | undefined, entry: BlockedAttemptEntry): BlockedAttemptEntry[] {
  const next = [...(list ?? []), entry];
  next.sort((a, b) => Date.parse(b.at) - Date.parse(a.at));
  return next.slice(0, BLOCKED_ATTEMPTS_CAP);
}

/** What one attempt shows in the parent's list: the site with names on, the app's label or package. */
export function attemptEntry(kind: BlockedKind, subject: string, metadata: Record<string, unknown>, at: string): BlockedAttemptEntry {
  if (kind === "web") return subject ? { at, site: subject } : { at };
  const label = typeof metadata.appName === "string" ? metadata.appName.replace(/\s+/g, " ").trim().slice(0, 80) : "";
  const app = label || subject;
  return app ? { at, app } : { at };
}

export function parseBlockedGroup(raw: unknown): BlockedGroupState | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const g = (raw as Record<string, unknown>).blockGroup;
  if (!g || typeof g !== "object" || Array.isArray(g)) return null;
  const m = g as Record<string, unknown>;
  if ((m.kind !== "web" && m.kind !== "app") || typeof m.latestAt !== "string" || typeof m.day !== "string") return null;
  return {
    kind: m.kind,
    day: m.day,
    firstAt: typeof m.firstAt === "string" ? m.firstAt : m.latestAt,
    latestAt: m.latestAt,
    pushedCount: typeof m.pushedCount === "number" && Number.isSafeInteger(m.pushedCount) && m.pushedCount >= 0 ? m.pushedCount : 0,
    ...(typeof m.lastPushAt === "string" ? { lastPushAt: m.lastPushAt } : {}),
    summaryPending: m.summaryPending === true,
    ...(typeof m.summaryDueAt === "string" ? { summaryDueAt: m.summaryDueAt } : {}),
    ...(typeof m.summaryPushedAt === "string" ? { summaryPushedAt: m.summaryPushedAt } : {}),
    ...(Array.isArray(m.attempts) ? { attempts: parseAttempts(m.attempts) } : {}),
  };
}

/**
 * osra-security#88: the producer key can carry a site or app name (for example a host), and receipt keys outlive
 * the alert. Receipt keys therefore hold only a keyed, domain-separated fingerprint of the producer key, never the
 * key itself, so a Redis dump shows no site even while site names are off. Same secrets as the social contact key.
 */
function blockedReceiptSalt(env: NodeJS.ProcessEnv = process.env): Buffer {
  const baseSecret = env.VAULT_KEY || env.INTERNAL_HMAC_SECRET;
  if (baseSecret) return createHmac("sha256", baseSecret).update("osra:blocked-receipt:v1").digest();
  if (env.NODE_ENV === "production") throw new Error("VAULT_KEY or INTERNAL_HMAC_SECRET is required in production");
  return Buffer.from("dev-blocked-receipt-salt", "utf8");
}

export function blockedProducerFingerprint(
  deviceId: string,
  category: string,
  producerKey: string,
  env: NodeJS.ProcessEnv = process.env,
): string {
  return createHmac("sha256", blockedReceiptSalt(env))
    .update(`${deviceId}\u0000${category}\u0000${producerKey}`)
    .digest("hex")
    .slice(0, 32);
}

/** Device retries: the phone's own per-day count, remembered per (device, category, producer key fingerprint). */
export function blockedSeenKey(deviceId: string, category: string, producerKey: string, env: NodeJS.ProcessEnv = process.env): string {
  return `blocked:seen:${deviceId}:${category}:${blockedProducerFingerprint(deviceId, category, producerKey, env)}`;
}

export const BLOCKED_SEEN_TTL_SECONDS = 2 * 24 * 60 * 60;

export interface RecordBlockedAttemptInput {
  childId: string;
  familyId: string;
  childName?: string | null;
  deviceId?: string | null;
  timeZone?: string | null;
  category: (typeof BLOCKED_GROUP_CATEGORIES)[number];
  severity: "info" | "warning" | "critical";
  title: string;
  body: string;
  metadata: Record<string, unknown>;
  siteNames: boolean;
  /** The producer's own key and running count, used only to recognise a lost-response retry. */
  producerKey?: string | null;
  producerAttemptCount?: number | null;
  now?: Date;
  env?: NodeJS.ProcessEnv;
}

export interface RecordBlockedAttemptResult {
  alert: Alert;
  created: boolean;
  pushed: boolean;
  retry: boolean;
}

/**
 * Codex (#1228 finding 1): two in-flight copies of one attempt could both pass the seen-count read before either
 * wrote it, counting and pushing twice. The attempt identity (device, category, producer key, producer count) is
 * now claimed with SET NX before anything is counted or pushed; a copy that loses the claim is a retry. If the
 * write then fails, the claim is released so the phone's normal retry still records the attempt.
 * Codex (#1228 [Sat] point 2): the kept claim (two days) is also the retry test, by exact identity. A distinct
 * attempt with a lower producer count that arrives after a higher one (reconnect, reordering) is new and counted;
 * only the very same (key, count) is a retry.
 */
export function blockedClaimKey(
  deviceId: string,
  category: string,
  producerKey: string,
  count: number,
  env: NodeJS.ProcessEnv = process.env,
): string {
  return `blocked:claim:${deviceId}:${category}:${blockedProducerFingerprint(deviceId, category, producerKey, env)}:${count}`;
}

type Claim = { key: string } | null | "lost";

async function claimAttempt(redis: ReturnType<typeof getRedis>, input: RecordBlockedAttemptInput): Promise<Claim> {
  if (!input.deviceId || !input.producerKey || !input.producerAttemptCount) return null;
  const key = blockedClaimKey(input.deviceId, input.category, input.producerKey, input.producerAttemptCount, input.env ?? process.env);
  try {
    const ok = await redis.set(key, "1", "EX", BLOCKED_SEEN_TTL_SECONDS, "NX");
    return ok === "OK" ? { key } : "lost";
  } catch {
    return null; // Redis down: record the attempt rather than drop it, as before.
  }
}

async function releaseClaim(redis: ReturnType<typeof getRedis>, claim: Claim): Promise<void> {
  if (claim && claim !== "lost") await redis.del(claim.key).catch(() => undefined);
}

async function rememberSeen(redis: ReturnType<typeof getRedis>, input: RecordBlockedAttemptInput): Promise<void> {
  if (!input.deviceId || !input.producerKey || !input.producerAttemptCount) return;
  await redis
    .set(blockedSeenKey(input.deviceId, input.category, input.producerKey, input.env ?? process.env), String(input.producerAttemptCount), "EX", BLOCKED_SEEN_TTL_SECONDS)
    .catch(() => undefined);
}

function openRow(childId: string, category: string, prefix: string) {
  return prisma.alert.findFirst({
    where: { childId, category, dedupeKey: { startsWith: prefix }, heldDuringSetup: false },
    orderBy: { createdAt: "desc" },
  });
}

/** Records one blocked attempt against its run, pushing only inside the (child, kind) budget. */
export async function recordBlockedAttempt(input: RecordBlockedAttemptInput): Promise<RecordBlockedAttemptResult> {
  const env = input.env ?? process.env;
  const now = input.now ?? new Date();
  const nowMs = now.getTime();
  const nowIso = now.toISOString();
  const windowMs = socialAlertWindowMs(env);
  const kind = blockedKindFor(input.category) as BlockedKind;
  const subject = blockedSubject(kind, input.metadata, input.siteNames);
  const day = familyLocalDay(now, input.timeZone);
  const prefix = blockedGroupPrefix(kind, subject, day);
  const redis = getRedis();

  const retryResult = async (): Promise<RecordBlockedAttemptResult | null> => {
    const existing = await openRow(input.childId, input.category, prefix);
    return existing ? { alert: existing, created: false, pushed: false, retry: true } : null;
  };
  const claim = await claimAttempt(redis, input);
  if (claim === "lost") {
    const existing = await retryResult();
    if (existing) return existing;
    // The winning copy has not written its row yet: answer with nothing new rather than count it twice.
    throw Object.assign(new Error("blocked attempt already in flight"), { statusCode: 409 });
  }
  try {
    return await recordClaimed(input, { env, now, nowMs, nowIso, windowMs, kind, subject, day, prefix, redis });
  } catch (err) {
    await releaseClaim(redis, claim);
    throw err;
  }
}

interface AttemptContext {
  env: NodeJS.ProcessEnv;
  now: Date;
  nowMs: number;
  nowIso: string;
  windowMs: number;
  kind: BlockedKind;
  subject: string;
  day: string;
  prefix: string;
  redis: ReturnType<typeof getRedis>;
}

async function recordClaimed(input: RecordBlockedAttemptInput, ctx: AttemptContext): Promise<RecordBlockedAttemptResult> {
  const { env, nowMs, nowIso, windowMs, kind, subject, day, prefix, redis } = ctx;
  const entry = attemptEntry(kind, subject, input.metadata, nowIso);
  const pushNow = await takeSocialPushBudget(redis, input.childId, blockedBudgetName(kind), env);

  for (let attempt = 0; attempt < 6; attempt += 1) {
    const open = await openRow(input.childId, input.category, prefix);
    const group = open ? parseBlockedGroup(open.metadata) : null;
    const latestMs = group ? Date.parse(group.latestAt) : Number.NaN;
    if (open && group && Number.isFinite(latestMs) && nowMs - latestMs < windowMs) {
      const prevMeta = (open.metadata && typeof open.metadata === "object" && !Array.isArray(open.metadata)
        ? open.metadata
        : {}) as Record<string, unknown>;
      const prevCount = open.attemptCount ?? 1;
      const nextCount = prevCount + 1;
      const summaryDueAt = pushNow
        ? undefined
        : group.summaryPending && group.summaryDueAt
          ? group.summaryDueAt
          : new Date(Math.max(nowMs, Date.parse(group.lastPushAt ?? group.firstAt) + windowMs)).toISOString();
      // Codex (#1228 finding 2): an attempt received earlier can finish later; the group never moves backwards.
      const latestIso = nowMs > latestMs ? nowIso : group.latestAt;
      const nextGroup: BlockedGroupState = {
        ...group,
        firstAt: Date.parse(group.firstAt) > nowMs ? nowIso : group.firstAt,
        latestAt: latestIso,
        attempts: withAttempt(group.attempts, entry),
        pushedCount: pushNow ? nextCount : group.pushedCount,
        ...(pushNow ? { lastPushAt: nowIso } : {}),
        summaryPending: !pushNow,
        ...(summaryDueAt ? { summaryDueAt } : {}),
      };
      if (pushNow) delete nextGroup.summaryDueAt;
      const nextMetadata: Record<string, unknown> = {
        ...prevMeta,
        ...input.metadata,
        latestAt: latestIso,
        blockGroup: nextGroup,
        ...(pushNow ? nextPushDelivery(prevMeta, nowIso) : {}),
      };
      const res = await prisma.alert.updateMany({
        where: { id: open.id, attemptCount: prevCount },
        data: { attemptCount: nextCount, acknowledged: false, metadata: nextMetadata as Prisma.InputJsonValue },
      });
      if (res.count !== 1) continue;
      const updated = (await prisma.alert.findUnique({ where: { id: open.id } })) ?? {
        ...open,
        attemptCount: nextCount,
        acknowledged: false,
        metadata: nextMetadata as Prisma.JsonValue,
      };
      await publishFamilyEvent(input.familyId, { type: "alert", payload: updated, ts: nowIso });
      if (pushNow) await notifyParentsOfAlert(input.familyId, updated, input.childName ?? undefined);
      await rememberSeen(redis, input);
      return { alert: updated, created: false, pushed: pushNow, retry: false };
    }

    const newGroup: BlockedGroupState = {
      kind,
      day,
      firstAt: nowIso,
      latestAt: nowIso,
      attempts: [entry],
      pushedCount: pushNow ? 1 : 0,
      ...(pushNow ? { lastPushAt: nowIso } : { summaryDueAt: new Date(nowMs + windowMs).toISOString() }),
      summaryPending: !pushNow,
    };
    const { alert, deduplicated } = await raiseAlertOnce({
      childId: input.childId,
      familyId: input.familyId,
      deviceId: input.deviceId,
      severity: input.severity,
      category: input.category,
      title: input.title,
      body: input.body,
      metadata: {
        ...input.metadata,
        latestAt: nowIso,
        blockGroup: newGroup,
        // A silent row carries sequence 0, so the parent app shows nothing for it until its summary.
        ...(pushNow ? nextPushDelivery(undefined, nowIso) : { pushDeliverySeq: 0 }),
      },
      dedupeKey: `${prefix}${nowMs}`,
      attemptCount: 1,
      childName: input.childName ?? undefined,
      skipPush: !pushNow,
    });
    if (deduplicated) continue;
    await rememberSeen(redis, input);
    return { alert, created: true, pushed: pushNow, retry: false };
  }

  // Every compare-and-set lost to a concurrent attempt: report the newest row rather than fail the device.
  const latest = await openRow(input.childId, input.category, prefix);
  if (!latest) throw new Error("blocked attempt could not be recorded");
  return { alert: latest, created: false, pushed: false, retry: false };
}

export { socialAlertWindowSeconds as blockedWindowSeconds };
