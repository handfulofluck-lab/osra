import { Prisma } from "@prisma/client";
import { prisma } from "../../db.js";
import { FcmProvider, loadServiceAccountFromEnv } from "./fcm.js";
import { ApnsProvider, loadApnsConfigFromEnv } from "./apns.js";
import type { PushMessage, PushPlatform, PushProvider } from "./types.js";

/**
 * Parent notification policy (Phase 2a). Given an alert, decide which parents' devices receive a
 * push, build one message, fan it out through the configured providers, and prune dead tokens.
 *
 * Providers are resolved once from env. With none configured the registry is empty and
 * `notifyParentsOfAlert` is a no-op that logs once per process — the API never fails an alert
 * write because push is unavailable.
 */

export interface AlertLike {
  id: string;
  childId: string;
  severity: string;
  category: string;
  title: string;
  body: string;
  createdAt?: Date | string;
  metadata?: unknown;
}

type Severity = "info" | "warning" | "critical";
const SEVERITY_RANK: Record<Severity, number> = { info: 0, warning: 1, critical: 2 };
const GROUPED_DELIVERY_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** Alerts at or above this severity are pushed. Env `PUSH_MIN_SEVERITY`, default "info". */
export function minPushSeverity(env: NodeJS.ProcessEnv = process.env): Severity {
  const v = env.PUSH_MIN_SEVERITY as Severity | undefined;
  return v && v in SEVERITY_RANK ? v : "info";
}

export function shouldPush(alert: Pick<AlertLike, "severity" | "category"> | null | undefined, min: Severity): boolean {
  if (!alert) return false;
  const sev = (alert.severity as Severity) in SEVERITY_RANK ? (alert.severity as Severity) : "info";
  // Issue #889 (UI/UX Bureau ruling): routine `info` restarts (< 30 min gap) stay in the Alerts list
  // and unread badge without waking the parent's phone; `warning` restarts (>= 30 min gap) still push.
  if (alert.category === "device_restarted" && sev === "info") return false;
  // SOS and tamper always wake the parent regardless of the floor.
  if (alert.category === "sos" || alert.category === "tamper") return true;
  return SEVERITY_RANK[sev] >= SEVERITY_RANK[min];
}

/**
 * The parent alert message for one platform (#410, decision 1 and 2).
 *
 * **No alert content leaves the server in a parent push, on any platform.** The app already fetches
 * `/v1/alerts` and builds the notification locally (#395), and a payload carrying `<child name>: <title>`
 * plus the alert body would put a child's name and their search or video title through Google and Apple —
 * which is what the Flip4 run caught as a second, duplicate notification.
 *
 * - **Android**: `dataOnly`, `{ w: "1" }` and nothing else, `HIGH` priority because the app has to wake to
 *   fetch, and a constant collapse key because one wake reads every unseen alert.
 * - **iOS**: a visible alert built from localization keys, plus `content-available`. The bundle decides
 *   the words. For grouped social deliveries, the content-free `g` marker selects native presentation,
 *   and an opaque UUID lets APNs collapse retries of that delivery independently of the display thread.
 *
 * The child-device wake keeps its own builder: it must never display anything, which is a different rule.
 */
export function buildParentAlertMessage(
  platform: PushPlatform,
  alert?: Pick<AlertLike, "category" | "metadata">,
): PushMessage {
  const data = { w: "1" };
  if (platform === "ios") {
    const deliveryId = groupedDeliveryId(alert);
    return {
      data: deliveryId ? { ...data, g: "1" } : data,
      locKeys: { titleKey: "PUSH_ALERT_TITLE", bodyKey: "PUSH_ALERT_BODY" },
      priority: "high",
      collapseKey: PARENT_WAKE_COLLAPSE_KEY,
      threadId: PARENT_WAKE_COLLAPSE_KEY,
      ...(deliveryId ? { apnsCollapseId: deliveryId } : {}),
    };
  }
  return { data, dataOnly: true, priority: "high", collapseKey: PARENT_WAKE_COLLAPSE_KEY, threadId: PARENT_WAKE_COLLAPSE_KEY };
}

function groupedDeliveryId(alert: Pick<AlertLike, "category" | "metadata"> | undefined): string | undefined {
  if (alert?.category !== "social_concern" && alert?.category !== "gaming_chat") return undefined;
  const metadata = alert.metadata;
  if (typeof metadata !== "object" || metadata === null || Array.isArray(metadata)) return undefined;
  const { pushDeliveryId, pushDeliverySeq } = metadata as Record<string, unknown>;
  if (typeof pushDeliverySeq !== "number" || !Number.isSafeInteger(pushDeliverySeq) || pushDeliverySeq < 1) {
    return undefined;
  }
  // Only server-issued v4 UUIDs fit this contract. They are opaque, ASCII and within the APNs limit.
  return typeof pushDeliveryId === "string" && pushDeliveryId.length === 36 && GROUPED_DELIVERY_ID.test(pushDeliveryId)
    ? pushDeliveryId
    : undefined;
}

/** One constant key: every unseen alert is read by the same wake, so a second pending wake is redundant. */
export const PARENT_WAKE_COLLAPSE_KEY = "osra-wake";

/** Registry of providers keyed by platform. Built lazily from env; replaceable in tests. */
let registry: Map<PushPlatform, PushProvider> | null = null;
let warnedUnconfigured = false;

export function setPushProviders(providers: PushProvider[] | null): void {
  registry = providers ? new Map(providers.map((p) => [p.platform, p])) : null;
  warnedUnconfigured = false;
}

export function getPushProviders(): Map<PushPlatform, PushProvider> {
  if (registry) return registry;
  const providers: PushProvider[] = [];
  const sa = loadServiceAccountFromEnv();
  if (sa) providers.push(new FcmProvider(sa));
  const apns = loadApnsConfigFromEnv();
  if (apns) providers.push(new ApnsProvider(apns));
  registry = new Map(providers.map((p) => [p.platform, p]));
  return registry;
}

/**
 * A parent's token is always an FCM token: the parent app mints it with `firebase_messaging` on Android and
 * on iOS alike (#360), and the Firebase JS SDK mints web tokens too. So every parent platform rides the FCM
 * provider. APNs would answer BadDeviceToken for an FCM token, which reads as dead and would prune the row
 * on every alert (#391 review). Raw APNs tokens are the child iPhone's only ([deviceWakeProviderFor]).
 */
function providerFor(_platform: PushPlatform, providers: Map<PushPlatform, PushProvider>): PushProvider | undefined {
  return providers.get("android");
}

/**
 * The provider that can wake a child device. A child iPhone's token is a raw APNs token (5.5 PR D): only
 * APNs can deliver it, and only under the child agent's topic. FCM answers 400 INVALID_ARGUMENT for it,
 * which reads as a dead token and would clear it, so an iPhone never falls back to FCM here. Parents' tokens
 * are FCM tokens on every platform, so they go through [providerFor] instead.
 */
function deviceWakeProviderFor(platform: PushPlatform, providers: Map<PushPlatform, PushProvider>): PushProvider | undefined {
  if (platform === "ios") {
    const apns = providers.get("ios");
    return apns?.canWakeDevices ? apns : undefined;
  }
  return providerFor(platform, providers);
}

/**
 * Could [notifyDeviceWake] reach this device right now: a token on file and a provider for its
 * platform. It says nothing about delivery (#353 uses it to choose the poll cadence, and a token the
 * provider rejects is cleared on the first failed wake, which flips this to false for the next poll).
 */
export function canWakeDevice(device: { platform?: string | null; pushToken?: string | null } | null | undefined): boolean {
  if (!device?.pushToken) return false;
  return deviceWakeProviderFor((device.platform ?? "android") as PushPlatform, getPushProviders()) !== undefined;
}

export interface NotifyOutcome {
  recipients: number;
  delivered: number;
  pruned: number;
  skipped: "severity" | "no_providers" | "no_tokens" | "prefs" | null;
}

export type PushErrorClass =
  | "unregistered"
  | "topic_mismatch"
  | "invalid_token"
  | "third_party_auth"
  | "auth_error"
  | "rate_limited"
  | "invalid_request"
  | "provider_unavailable"
  | "network_error"
  | "provider_error";

type CleanupStatus = "none" | "ok" | "failed";
type OutcomeSkipLabel = NonNullable<NotifyOutcome["skipped"]> | "error" | "none";

const KNOWN_PLATFORMS = new Set(["android", "ios", "web"]);
const KNOWN_SEVERITIES = new Set(["info", "warning", "critical"]);

function safePlatform(value: unknown): string {
  return typeof value === "string" && KNOWN_PLATFORMS.has(value) ? value : "unknown";
}

function safeSeverity(value: unknown): string {
  return typeof value === "string" && KNOWN_SEVERITIES.has(value) ? value : "none";
}

function safeCategory(value: unknown): string {
  return typeof value === "string" && /^[a-z0-9_]{1,40}$/.test(value) ? value : "none";
}

/**
 * Bucket a failed provider response into a closed operator-scannable error class (#1028).
 * Distinguishes APNs/Firebase third-party auth mismatches (`THIRD_PARTY_AUTH_ERROR`) from
 * dead tokens, OAuth failures, rate limits, malformed payloads, and transient provider outages.
 */
export function classifyPushError(result: { invalidToken?: boolean; reason?: string }): PushErrorClass {
  const reason = (result.reason ?? "").trim();
  if (/\b(UNREGISTERED|Unregistered|NOT_FOUND)\b/.test(reason) || /\bHTTP (404|410)\b/.test(reason)) {
    return "unregistered";
  }
  if (/\bDeviceTokenNotForTopic\b/.test(reason)) {
    return "topic_mismatch";
  }
  if (result.invalidToken || /\bBadDeviceToken\b/.test(reason)) {
    return "invalid_token";
  }
  if (/\bTHIRD_PARTY_AUTH_ERROR\b/.test(reason)) {
    return "third_party_auth";
  }
  if (
    /\b(SENDER_ID_MISMATCH|UNAUTHENTICATED|PERMISSION_DENIED|InvalidProviderToken|ExpiredProviderToken|BadCertificate|BadCertificateEnvironment)\b/.test(
      reason,
    ) ||
    /\bHTTP (401|403)\b/.test(reason) ||
    /oauth/i.test(reason)
  ) {
    return "auth_error";
  }
  if (/\b(QUOTA_EXCEEDED|TooManyRequests)\b/.test(reason) || /\bHTTP 429\b/.test(reason)) {
    return "rate_limited";
  }
  if (/\b(INVALID_ARGUMENT|BadMessageId|PayloadTooLarge)\b/.test(reason) || /\bHTTP 400\b/.test(reason)) {
    return "invalid_request";
  }
  if (/\b(UNAVAILABLE|INTERNAL|ServiceUnavailable|InternalServerError)\b/.test(reason) || /\bHTTP 5\d\d\b/.test(reason)) {
    return "provider_unavailable";
  }
  if (/\b(ECONNRESET|ECONNREFUSED|ETIMEDOUT|EPIPE|EAI_AGAIN|ENOTFOUND|socket|fetch failed|network|timeout)\b/i.test(reason)) {
    return "network_error";
  }
  return "provider_error";
}

function logParentAlertOutcome(summary: {
  recipients: number;
  delivered: number;
  stale: number;
  pruned: number;
  failed: number;
  cleanup: CleanupStatus;
  skipped: OutcomeSkipLabel;
  category?: unknown;
  severity?: unknown;
  platforms?: string;
}): void {
  const platformPart = summary.platforms ? ` platforms=${summary.platforms}` : "";
  console.info(
    `[push] parent alert outcome recipients=${summary.recipients} delivered=${summary.delivered} stale=${summary.stale} pruned=${summary.pruned} failed=${summary.failed} cleanup=${summary.cleanup} skipped=${summary.skipped} category=${safeCategory(summary.category)} severity=${safeSeverity(summary.severity)}${platformPart}`,
  );
}

/**
 * Fan an alert out to every push token of every parent in the family. Never throws: push is
 * best-effort and the alert row is already committed when this runs.
 *
 * [#1028] Every call writes exactly one aggregate outcome line (counts, stale vs pruned cleanup
 * status, skip reason, platform histogram, closed category/severity — never tokens, raw provider
 * strings, message ids, database ids, or exception objects) and every per-recipient send writes
 * one closed-classification line (platform, provider, status, errorClass).
 */
export async function notifyParentsOfAlert(familyId: string, alert: AlertLike, childName?: string): Promise<NotifyOutcome> {
  const outcome: NotifyOutcome = { recipients: 0, delivered: 0, pruned: 0, skipped: null };
  try {
    // Defensive: raiseAlert always passes the created row, but a caller with a mocked or failed
    // create must not turn into a TypeError in a fire-and-forget path (Antigravity review of #51).
    if (!alert) {
      logParentAlertOutcome({ recipients: 0, delivered: 0, stale: 0, pruned: 0, failed: 0, cleanup: "none", skipped: "severity" });
      return { ...outcome, skipped: "severity" };
    }
    if (!shouldPush(alert, minPushSeverity())) {
      logParentAlertOutcome({
        recipients: 0,
        delivered: 0,
        stale: 0,
        pruned: 0,
        failed: 0,
        cleanup: "none",
        skipped: "severity",
        category: alert.category,
        severity: alert.severity,
      });
      return { ...outcome, skipped: "severity" };
    }
    const providers = getPushProviders();
    if (providers.size === 0) {
      if (!warnedUnconfigured) {
        console.warn("[push] no provider configured (set FCM_SERVICE_ACCOUNT_JSON or APNS_*); parent push disabled");
        warnedUnconfigured = true;
      }
      logParentAlertOutcome({
        recipients: 0,
        delivered: 0,
        stale: 0,
        pruned: 0,
        failed: 0,
        cleanup: "none",
        skipped: "no_providers",
        category: alert.category,
        severity: alert.severity,
      });
      return { ...outcome, skipped: "no_providers" };
    }
    const prefs = await prisma.digestPrefs.findUnique({ where: { familyId } });
    if (prefs && prefs.pushEnabled === false) {
      logParentAlertOutcome({
        recipients: 0,
        delivered: 0,
        stale: 0,
        pruned: 0,
        failed: 0,
        cleanup: "none",
        skipped: "prefs",
        category: alert.category,
        severity: alert.severity,
      });
      return { ...outcome, skipped: "prefs" };
    }

    // ADR-0014 amendment, decision 3: a guardian without `alerts` must not be pushed an alert either,
    // or the gate on `GET /v1/alerts` would be cosmetic — the push *is* the alert text on a lock
    // screen. Owners and co-parents are unaffected, which is why only guardians are filtered.
    const { parents, rawTokens } = await prisma.$transaction(
      async (tx) => {
        const eligibleParents = await tx.parent.findMany({
          where: {
            familyId,
            OR: [{ role: { not: "guardian" } }, { role: "guardian", permissions: { has: "alerts" } }],
          },
          select: { id: true, sessionVersion: true },
        });
        const candidateTokens = eligibleParents.length === 0
          ? []
          : await tx.parentPushToken.findMany({
              where: { parentId: { in: eligibleParents.map((p) => p.id) } },
            });
        return { parents: eligibleParents, rawTokens: candidateTokens };
      },
      { isolationLevel: Prisma.TransactionIsolationLevel.RepeatableRead },
    );
    const minSessionVersionByParent = new Map(
      parents.map((p) => [p.id, typeof p.sessionVersion === "number" ? p.sessionVersion : 0]),
    );
    const retired: Array<{ id: string; parentId: string; minVersion: number }> = [];
    const tokens = rawTokens.filter((row) => {
      const rowVersion = typeof (row as { sessionVersion?: unknown }).sessionVersion === "number"
        ? ((row as { sessionVersion: number }).sessionVersion)
        : 0;
      const minVersion = minSessionVersionByParent.get(row.parentId) ?? 0;
      if (rowVersion < minVersion) {
        retired.push({ id: row.id, parentId: row.parentId, minVersion });
        return false;
      }
      return true;
    });
    if (retired.length > 0) {
      await prisma.parentPushToken.deleteMany({
        where: {
          OR: retired.map(({ id, parentId, minVersion }) => ({
            id,
            parentId,
            sessionVersion: { lt: minVersion },
          })),
        },
      }).catch(() => undefined);
    }
    if (tokens.length === 0) {
      logParentAlertOutcome({
        recipients: 0,
        delivered: 0,
        stale: 0,
        pruned: 0,
        failed: 0,
        cleanup: "none",
        skipped: "no_tokens",
        category: alert.category,
        severity: alert.severity,
      });
      return { ...outcome, skipped: "no_tokens" };
    }

    outcome.recipients = tokens.length;
    const dead: string[] = [];
    let failed = 0;
    const byPlatform = new Map<string, number>();
    for (const row of tokens) {
      const p = safePlatform(row.platform);
      byPlatform.set(p, (byPlatform.get(p) ?? 0) + 1);
    }
    const platforms = [...byPlatform.entries()]
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([platform, count]) => `${platform}:${count}`)
      .join(",");

    await Promise.all(
      tokens.map(async (t) => {
        const platformLabel = safePlatform(t.platform);
        const provider = providerFor(t.platform as PushPlatform, providers);
        if (!provider) {
          failed += 1;
          console.warn(`[push] parent alert send outcome=skipped platform=${platformLabel} errorClass=no_provider`);
          return;
        }
        // #410: per-platform, and never the alert's text. `childName` is deliberately unused here now.
        const message = buildParentAlertMessage(t.platform as PushPlatform, alert);
        try {
          const result = await provider.send(t.token, message);
          if (result.ok) {
            outcome.delivered += 1;
            console.info(`[push] parent alert send outcome=sent platform=${platformLabel} provider=${provider.platform}`);
          } else if (result.invalidToken) {
            dead.push(t.id);
            const errorClass = classifyPushError(result);
            console.info(
              `[push] parent alert send outcome=stale platform=${platformLabel} provider=${provider.platform} errorClass=${errorClass}`,
            );
          } else {
            failed += 1;
            const errorClass = classifyPushError(result);
            console.warn(
              `[push] delivery failed platform=${platformLabel} provider=${provider.platform} errorClass=${errorClass}`,
            );
          }
        } catch (sendErr) {
          failed += 1;
          const errorClass = classifyPushError({ reason: sendErr instanceof Error ? sendErr.message : undefined });
          console.warn(
            `[push] delivery failed platform=${platformLabel} provider=${provider.platform} errorClass=${errorClass}`,
          );
        }
      }),
    );

    let cleanup: CleanupStatus = "none";
    if (dead.length > 0) {
      try {
        const deleted = await prisma.parentPushToken.deleteMany({ where: { id: { in: dead } } });
        outcome.pruned = typeof deleted?.count === "number" ? deleted.count : 0;
        cleanup = "ok";
      } catch {
        outcome.pruned = 0;
        cleanup = "failed";
        console.error("[push] parent alert cleanup failed errorClass=cleanup_failed");
      }
    }

    logParentAlertOutcome({
      recipients: outcome.recipients,
      delivered: outcome.delivered,
      stale: dead.length,
      pruned: outcome.pruned,
      failed,
      cleanup,
      skipped: "none",
      category: alert.category,
      severity: alert.severity,
      platforms,
    });
    return outcome;
  } catch (err) {
    const errorClass = classifyPushError({ reason: err instanceof Error ? err.message : undefined });
    console.error(`[push] notifyParentsOfAlert failed errorClass=${errorClass}`);
    logParentAlertOutcome({
      recipients: outcome.recipients,
      delivered: outcome.delivered,
      stale: 0,
      pruned: outcome.pruned,
      failed: 0,
      cleanup: "none",
      skipped: "error",
      category: alert?.category,
      severity: alert?.severity,
    });
    return outcome;
  }
}

/* ───────────────────────── the child device wake (#319) ───────────────────────── */

/**
 * A push to a child device is a **wake-up only** (Claude's Decision 2, issue #319, 2026-10-23). The
 * message carries no command type, no payload and no ids — just "there is something to fetch" — and
 * the agent then drains `GET /v1/devices/:id/commands` over its own authenticated channel, acking as
 * it always has.
 *
 * **Why the push carries nothing:** Google (and anyone holding a stale or misdirected token) must not
 * see command content. `show_reset_code` carries a parent's reset code; a `locate_now` request carries
 * the timing of a family's day. A wake-up leaks neither, and the same idempotent ack path serves both
 * poll and push, so there is only one way a command ever takes effect.
 *
 * The literal is `{ "w": "1" }` — deliberately **not** a `type` field (Claude's ruling, 2026-10-23,
 * replacing the looser `{type:"wake"}` in his earlier note). An agent built before the #322 client
 * change reads `msg.data["type"] ?: return` and then hands the value to `CommandDispatcher`, which
 * would log "refusing unknown command type 'wake'". With `w` it returns at the `?:` and does nothing,
 * so a pre-#322 agent treats a wake as the no-op it should be.
 *
 * The current client asserts that it reads nothing from the data map at all (apps/child-android,
 * `PushWakeHandlerTest`), so this value can change for an up-to-date agent without touching it; it
 * exists so an operator reading logs or a captured packet can tell a wake from an alert.
 */
export const DEVICE_WAKE_DATA: Readonly<Record<string, string>> = Object.freeze({ w: "1" });

/** The one message shape a child device may receive. Exported so a test can assert it has no command fields. */
export function buildDeviceWakeMessage(): PushMessage {
  return {
    data: { ...DEVICE_WAKE_DATA },
    // Collapse key: ten commands in a second must cost one wake-up, because the agent drains the
    // whole queue on the first one. Nothing about the command is in the key — it is the word "wake".
    threadId: "wake",
    priority: "high",
    dataOnly: true,
  };
}

export interface WakeOutcome {
  delivered: number;
  clearedToken: boolean;
  skipped: "no_providers" | "no_token" | "unsupported_platform" | null;
}

/**
 * Wake one child device. Never throws: the command row is already committed and published when this
 * runs, and a push outage must not fail a parent's command.
 *
 * [#673] The Flip4 run of 12 Nov timed a `resume_internet` at 52.4 s and the API log held no line for
 * any wake it had sent, so a push that was never sent could not be told from one FCM delivered late.
 * Every attempt now writes one info line with the command id, FCM's message id (or the error) and the
 * priority used; a wake that never left is a line too, because "no line" kept two meanings.
 *
 * A token the provider reports as dead is cleared from the row (`UNREGISTERED` / 404 / invalid), which
 * is the only place a device token is ever removed — the agent re-registers on its next `onNewToken`
 * or poll tick.
 */
export async function notifyDeviceWake(deviceId: string, commandId?: string): Promise<WakeOutcome> {
  const outcome: WakeOutcome = { delivered: 0, clearedToken: false, skipped: null };
  // The command id and the device are on every line this call can write, so the fields live once.
  const tag = `[push] device wake command=${commandId ?? "none"} device=${deviceId}`;
  try {
    const providers = getPushProviders();
    if (providers.size === 0) {
      // Deliberately no per-call line: this is a process-wide configuration fact, and the warning
      // below already says it once. There is no device-level "did it go out" question to answer.
      if (!warnedUnconfigured) {
        console.warn("[push] no provider configured (set FCM_SERVICE_ACCOUNT_JSON or APNS_*); device wake disabled");
        warnedUnconfigured = true;
      }
      return { ...outcome, skipped: "no_providers" };
    }
    const device = await prisma.device.findUnique({ where: { id: deviceId }, select: { id: true, pushToken: true, platform: true } });
    if (!device?.pushToken) {
      console.info(`${tag} skipped skip=no_token`);
      return { ...outcome, skipped: "no_token" };
    }
    const provider = deviceWakeProviderFor(device.platform as PushPlatform, providers);
    if (!provider) {
      console.info(`${tag} skipped skip=unsupported_platform`);
      return { ...outcome, skipped: "unsupported_platform" };
    }

    const message = buildDeviceWakeMessage();
    const result = await provider.send(device.pushToken, message);
    const sent = `provider=${provider.platform} priority=${message.priority}`;
    if (result.ok) {
      console.info(`${tag} sent ${sent} messageId=${result.messageId ?? "unreported"}`);
      return { ...outcome, delivered: 1 };
    }
    if (result.invalidToken) {
      // Compare-and-clear (Claude's #323 review). Clearing by id alone would erase a token that
      // rotated while this send was in flight: onNewToken uploads the new one, this stale send comes
      // back UNREGISTERED, and the blanket clear then wipes the *new* token — which the agent never
      // re-uploads, because PushTokenUploadPolicy sees stored == uploaded. Push to that phone would be
      // dead until the next rotation, with no error anywhere. The `pushToken` condition also means a
      // device deleted mid-send is a no-op instead of a throw inside this try.
      const cleared = await prisma.device.updateMany({
        where: { id: deviceId, pushToken: device.pushToken },
        data: { pushToken: null },
      });
      console.info(`${tag} failed ${sent} reason=${result.reason} tokenCleared=${cleared.count > 0}`);
      return { ...outcome, clearedToken: cleared.count > 0 };
    }
    console.info(`${tag} failed ${sent} reason=${result.reason}`);
    return outcome;
  } catch (err) {
    console.error(`${tag} threw`, err);
    return outcome;
  }
}

/**
 * Test seam: swap the wake sender so a command-path test can assert the fan-out without a provider.
 * Production leaves it as [notifyDeviceWake]. The second argument is the command id (#673): a fake may
 * ignore it, and the wake log is where it is used.
 */
let deviceWakeSender: (deviceId: string, commandId?: string) => Promise<WakeOutcome> = notifyDeviceWake;

export function setDeviceWakeSender(fn: ((deviceId: string, commandId?: string) => Promise<WakeOutcome>) | null): void {
  deviceWakeSender = fn ?? notifyDeviceWake;
}

export function getDeviceWakeSender(): (deviceId: string, commandId?: string) => Promise<WakeOutcome> {
  return deviceWakeSender;
}

/**
 * Fire-and-forget wake from a synchronous-ish path. The invocation happens **synchronously** (so a
 * test can observe it), the promise is detached (so a slow Google round trip never delays a parent's
 * command), and a rejection is swallowed because `notifyDeviceWake` already logs its own failures.
 *
 * [commandId] is the `DeviceCommand` row this wake is for, carried only so the log line can name it
 * (#673). It is not part of the push: the payload stays `{ "w": "1" }`.
 */
export function wakeDeviceDetached(deviceId: string, commandId?: string): void {
  try {
    void deviceWakeSender(deviceId, commandId).catch(() => undefined);
  } catch {
    /* a sender that throws synchronously is not allowed to fail the caller */
  }
}
