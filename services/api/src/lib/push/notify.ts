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
}

type Severity = "info" | "warning" | "critical";
const SEVERITY_RANK: Record<Severity, number> = { info: 0, warning: 1, critical: 2 };

/** Alerts at or above this severity are pushed. Env `PUSH_MIN_SEVERITY`, default "info". */
export function minPushSeverity(env: NodeJS.ProcessEnv = process.env): Severity {
  const v = env.PUSH_MIN_SEVERITY as Severity | undefined;
  return v && v in SEVERITY_RANK ? v : "info";
}

export function shouldPush(alert: Pick<AlertLike, "severity" | "category"> | null | undefined, min: Severity): boolean {
  if (!alert) return false;
  const sev = (alert.severity as Severity) in SEVERITY_RANK ? (alert.severity as Severity) : "info";
  // SOS and tamper always wake the parent regardless of the floor.
  if (alert.category === "sos" || alert.category === "tamper") return true;
  return SEVERITY_RANK[sev] >= SEVERITY_RANK[min];
}

/** One message for every recipient: the alert's own title/body plus a data payload the app deep-links on. */
export function buildAlertMessage(alert: AlertLike, childName?: string): PushMessage {
  const critical = alert.severity === "critical" || alert.category === "sos";
  return {
    title: childName ? `${childName}: ${alert.title}` : alert.title,
    body: alert.body,
    data: {
      type: "alert",
      alertId: alert.id,
      childId: alert.childId,
      category: alert.category,
      severity: alert.severity,
    },
    threadId: `child-${alert.childId}`,
    priority: critical ? "high" : "normal",
  };
}

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

/**
 * Fan an alert out to every push token of every parent in the family. Never throws: push is
 * best-effort and the alert row is already committed when this runs.
 */
export async function notifyParentsOfAlert(familyId: string, alert: AlertLike, childName?: string): Promise<NotifyOutcome> {
  const outcome: NotifyOutcome = { recipients: 0, delivered: 0, pruned: 0, skipped: null };
  try {
    // Defensive: raiseAlert always passes the created row, but a caller with a mocked or failed
    // create must not turn into a TypeError in a fire-and-forget path (Antigravity review of #51).
    if (!alert) return { ...outcome, skipped: "severity" };
    if (!shouldPush(alert, minPushSeverity())) return { ...outcome, skipped: "severity" };
    const providers = getPushProviders();
    if (providers.size === 0) {
      if (!warnedUnconfigured) {
        console.warn("[push] no provider configured (set FCM_SERVICE_ACCOUNT_JSON or APNS_*); parent push disabled");
        warnedUnconfigured = true;
      }
      return { ...outcome, skipped: "no_providers" };
    }
    const prefs = await prisma.digestPrefs.findUnique({ where: { familyId } });
    if (prefs && prefs.pushEnabled === false) return { ...outcome, skipped: "prefs" };

    const parents = await prisma.parent.findMany({ where: { familyId }, select: { id: true } });
    const tokens = await prisma.parentPushToken.findMany({ where: { parentId: { in: parents.map((p) => p.id) } } });
    if (tokens.length === 0) return { ...outcome, skipped: "no_tokens" };

    const message = buildAlertMessage(alert, childName);
    outcome.recipients = tokens.length;
    const dead: string[] = [];
    await Promise.all(
      tokens.map(async (t) => {
        const provider = providerFor(t.platform as PushPlatform, providers);
        if (!provider) return;
        const result = await provider.send(t.token, message);
        if (result.ok) outcome.delivered += 1;
        else if (result.invalidToken) dead.push(t.id);
        else console.warn(`[push] delivery failed platform=${t.platform} reason=${result.reason}`);
      }),
    );
    if (dead.length > 0) {
      await prisma.parentPushToken.deleteMany({ where: { id: { in: dead } } });
      outcome.pruned = dead.length;
    }
    return outcome;
  } catch (err) {
    console.error("[push] notifyParentsOfAlert failed", err);
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
 * A token the provider reports as dead is cleared from the row (`UNREGISTERED` / 404 / invalid), which
 * is the only place a device token is ever removed — the agent re-registers on its next `onNewToken`
 * or poll tick.
 */
export async function notifyDeviceWake(deviceId: string): Promise<WakeOutcome> {
  const outcome: WakeOutcome = { delivered: 0, clearedToken: false, skipped: null };
  try {
    const providers = getPushProviders();
    if (providers.size === 0) {
      if (!warnedUnconfigured) {
        console.warn("[push] no provider configured (set FCM_SERVICE_ACCOUNT_JSON or APNS_*); device wake disabled");
        warnedUnconfigured = true;
      }
      return { ...outcome, skipped: "no_providers" };
    }
    const device = await prisma.device.findUnique({ where: { id: deviceId }, select: { id: true, pushToken: true, platform: true } });
    if (!device?.pushToken) return { ...outcome, skipped: "no_token" };
    const provider = deviceWakeProviderFor(device.platform as PushPlatform, providers);
    if (!provider) return { ...outcome, skipped: "unsupported_platform" };

    const result = await provider.send(device.pushToken, buildDeviceWakeMessage());
    if (result.ok) return { ...outcome, delivered: 1 };
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
      return { ...outcome, clearedToken: cleared.count > 0 };
    }
    console.warn(`[push] device wake failed device=${deviceId} reason=${result.reason}`);
    return outcome;
  } catch (err) {
    console.error("[push] notifyDeviceWake failed", err);
    return outcome;
  }
}

/**
 * Test seam: swap the wake sender so a command-path test can assert the fan-out without a provider.
 * Production leaves it as [notifyDeviceWake].
 */
let deviceWakeSender: (deviceId: string) => Promise<WakeOutcome> = notifyDeviceWake;

export function setDeviceWakeSender(fn: ((deviceId: string) => Promise<WakeOutcome>) | null): void {
  deviceWakeSender = fn ?? notifyDeviceWake;
}

export function getDeviceWakeSender(): (deviceId: string) => Promise<WakeOutcome> {
  return deviceWakeSender;
}

/**
 * Fire-and-forget wake from a synchronous-ish path. The invocation happens **synchronously** (so a
 * test can observe it), the promise is detached (so a slow Google round trip never delays a parent's
 * command), and a rejection is swallowed because `notifyDeviceWake` already logs its own failures.
 */
export function wakeDeviceDetached(deviceId: string): void {
  try {
    void deviceWakeSender(deviceId).catch(() => undefined);
  } catch {
    /* a sender that throws synchronously is not allowed to fail the caller */
  }
}
