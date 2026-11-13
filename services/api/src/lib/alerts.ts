import type { Alert, Prisma } from "@prisma/client";
import { ALERT_BODY_KEYS, type AlertBodyKey, type AlertBodyParams } from "@familyshield/shared-types";
import { prisma } from "../db.js";
import { publishFamilyEvent } from "../realtime/gateway.js";
import { notifyParentsOfAlert } from "./push/notify.js";

/**
 * The one way an alert is raised (Phase 2a). Every producer — agent-signed `/alerts/internal`,
 * the social scan, content routes, geofence transitions — goes through here so that creating the
 * row, publishing the WebSocket event and pushing to the parents' phones can never drift apart
 * again (the audit found push wired to one of five producers, and that one was a `console.log`).
 */
export interface RaiseAlertInput {
  childId: string;
  familyId: string;
  deviceId?: string | null;
  severity: "info" | "warning" | "critical";
  category: string;
  title: string;
  body: string;
  /**
   * The parent app renders this key with params. An installed parent app that predates this change
   * renders `body`, so removing the English title/body would blank every alert on every un-updated
   * phone. The English pair is the compatibility floor; the key is the future.
   */
  bodyKey?: AlertBodyKey;
  params?: AlertBodyParams;
  metadata?: Record<string, unknown>;
  /** Shown as the push title prefix; looked up when omitted. */
  childName?: string;
  /**
   * Issue #225: producer-supplied idempotency key. When set, a second alert with the same
   * (deviceId, category, dedupeKey) is not inserted, published or pushed; the existing row is
   * returned with `deduplicated: true`. The DB's partial unique index is the race backstop.
   */
  dedupeKey?: string | null;
  /**
   * Issue #227: the number of attempts this alert aggregates. With a repeated `dedupeKey` and a
   * higher value, the existing row is updated in place (body, metadata, count) and the parent is
   * **not** pushed again; a lower or equal value is a retry and changes nothing. Omitted for the
   * #225 event key, which keeps its duplicate-is-a-no-op rule.
   */
  attemptCount?: number | null;
}

export type KeyedRaiseAlertInput = Omit<RaiseAlertInput, "bodyKey" | "params"> & {
  bodyKey: AlertBodyKey;
  params: AlertBodyParams;
};

const ALERT_BODY_REQUIRED_PARAMS = {
  alertBodyDeviceSilent: ["model", "minutes"],
  alertBodyGeofenceEnter: ["label", "radiusM"],
  alertBodyGeofenceExit: ["label", "radiusM"],
  alertBodySearchFlagged: ["engine"],
  alertBodySocialConcern: ["app"],
  // `channel` is deliberately NOT required: YouTubeWatchSchema defaults it to "", so a flagged video with no
  // channel is a real case, and the English body already copes with an empty one. A required param here would
  // mean no alert at all for that video (#718 review).
  alertBodyYouTubeFlagged: [],
} as const satisfies Record<AlertBodyKey, readonly string[]>;

/**
 * Never let the localization fields stop an alert. A key or a param that cannot be trusted costs the
 * *key*, not the alert: the row is written with the English `body` and the app falls back exactly as an
 * un-updated app does (#718 review). The one thing that still throws is a programmer error a test catches —
 * params without a key — because that is a caller mistake, not a runtime condition.
 */
function metadataWithAlertBody(input: RaiseAlertInput): Record<string, unknown> | undefined {
  if (input.bodyKey === undefined) {
    if (input.params !== undefined) throw new Error("Alert body params require a bodyKey");
    return input.metadata;
  }
  if (!(ALERT_BODY_KEYS as readonly string[]).includes(input.bodyKey)) {
    console.warn(`[alerts] unknown bodyKey "${input.bodyKey}"; raising the alert with the English body only`);
    return input.metadata;
  }
  const params = input.params ?? {};
  for (const name of ALERT_BODY_REQUIRED_PARAMS[input.bodyKey]) {
    const value = params[name];
    if (value === undefined || value === null || value === "") {
      console.warn(`[alerts] empty body param "${name}" for ${input.bodyKey}; raising the alert with the English body only`);
      return input.metadata;
    }
  }
  return { ...input.metadata, bodyKey: input.bodyKey, bodyParams: params };
}

/** A unique-constraint violation from Prisma (`P2002`), without importing the client's error class. */
function isUniqueViolation(e: unknown): boolean {
  return typeof e === "object" && e !== null && (e as { code?: string }).code === "P2002";
}

function findDuplicate(input: RaiseAlertInput & { dedupeKey: string }) {
  return prisma.alert.findFirst({
    where: {
      deviceId: input.deviceId ?? null,
      category: input.category,
      dedupeKey: input.dedupeKey,
    },
  });
}

/**
 * Issue #227: a repeat of an aggregate window key carries a higher count. Update the row in place
 * and publish the updated row (an open parent list refreshes); do **not** push — this is the same
 * alert, not a new page. A lower or equal count is a lost-response retry and is ignored, so an
 * out-of-order POST can never lower the visible count.
 */
async function applyAttemptCount(existing: Alert, input: RaiseAlertInput): Promise<Alert> {
  // No aggregate count -> the #225 rule: a duplicate key is a no-op, not an update.
  if (input.attemptCount == null) return existing;
  if (input.attemptCount <= (existing.attemptCount ?? 1)) return existing;
  // The `lt` condition makes the comparison atomic: two aggregate POSTs that race cannot let the
  // lower count overwrite the higher one.
  const { count } = await prisma.alert.updateMany({
    where: { id: existing.id, attemptCount: { lt: input.attemptCount } },
    data: {
      body: input.body,
      metadata: (input.metadata ?? existing.metadata ?? {}) as Prisma.InputJsonValue,
      attemptCount: input.attemptCount,
      // Issue #227 D2 (Claude's review): a parent who acknowledged "2 attempts" and then sees no
      // badge never learns the child kept trying. A higher count marks the row unread again, so the
      // badge and the list show it; it still never pushes (ADR-0029).
      acknowledged: false,
    },
  });
  if (count === 0) return existing;
  const alert = await prisma.alert.findUnique({ where: { id: existing.id } });
  if (!alert) return existing;
  await publishFamilyEvent(input.familyId, { type: "alert", payload: alert, ts: new Date().toISOString() });
  return alert;
}

/**
 * Raises an alert and says whether it was new. A duplicate key either returns the row that already
 * exists (#225) or applies a higher aggregate count to it (#227); neither pushes again — the parent
 * has already been paged for this alert. Only a higher count publishes, so an open parent list can
 * refresh.
 */
export async function raiseAlertOnce(
  input: RaiseAlertInput,
): Promise<{ alert: Alert; deduplicated: boolean }> {
  const normalizedInput = { ...input, metadata: metadataWithAlertBody(input) };
  const dedupeKey = normalizedInput.dedupeKey ?? null;

  if (dedupeKey) {
    const existing = await findDuplicate({ ...normalizedInput, dedupeKey });
    if (existing) return { alert: await applyAttemptCount(existing, normalizedInput), deduplicated: true };
  }

  let alert;
  try {
    alert = await prisma.alert.create({
      data: {
        childId: normalizedInput.childId,
        deviceId: normalizedInput.deviceId ?? undefined,
        severity: normalizedInput.severity,
        category: normalizedInput.category,
        title: normalizedInput.title,
        body: normalizedInput.body,
        metadata: (normalizedInput.metadata ?? {}) as Prisma.InputJsonValue,
        dedupeKey: dedupeKey ?? undefined,
        attemptCount: normalizedInput.attemptCount ?? 1,
      },
    });
  } catch (e) {
    // Two workers can pass the check above together; the partial unique index settles it.
    if (!dedupeKey || !isUniqueViolation(e)) throw e;
    const existing = await findDuplicate({ ...normalizedInput, dedupeKey });
    if (existing) return { alert: await applyAttemptCount(existing, normalizedInput), deduplicated: true };
    throw e;
  }

  await publishFamilyEvent(normalizedInput.familyId, { type: "alert", payload: alert, ts: new Date().toISOString() });

  let childName = normalizedInput.childName;
  if (!childName) {
    const child = await prisma.child.findUnique({ where: { id: normalizedInput.childId }, select: { displayName: true } });
    childName = child?.displayName;
  }
  // Fire-and-forget by contract: notifyParentsOfAlert never throws and must not delay the agent's
  // 201. Awaited here only so tests can observe it; the cost is one in-memory fan-out.
  await notifyParentsOfAlert(normalizedInput.familyId, alert, childName);
  return { alert, deduplicated: false };
}

/** Backwards-compatible wrapper for producers that do not use a dedupe key. */
export async function raiseAlert(input: KeyedRaiseAlertInput) {
  return (await raiseAlertOnce(input)).alert;
}
