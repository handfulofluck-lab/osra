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

export function shouldPush(alert: Pick<AlertLike, "severity" | "category">, min: Severity): boolean {
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

/** Web tokens are FCM tokens too (Firebase JS SDK), so they ride the Android provider. */
function providerFor(platform: PushPlatform, providers: Map<PushPlatform, PushProvider>): PushProvider | undefined {
  if (platform === "web") return providers.get("android");
  if (platform === "ios") return providers.get("ios") ?? providers.get("android");
  return providers.get(platform);
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
