import type { Alert, Prisma } from "@prisma/client";
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
  const dedupeKey = input.dedupeKey ?? null;

  if (dedupeKey) {
    const existing = await findDuplicate({ ...input, dedupeKey });
    if (existing) return { alert: await applyAttemptCount(existing, input), deduplicated: true };
  }

  let alert;
  try {
    alert = await prisma.alert.create({
      data: {
        childId: input.childId,
        deviceId: input.deviceId ?? undefined,
        severity: input.severity,
        category: input.category,
        title: input.title,
        body: input.body,
        metadata: (input.metadata ?? {}) as Prisma.InputJsonValue,
        dedupeKey: dedupeKey ?? undefined,
        attemptCount: input.attemptCount ?? 1,
      },
    });
  } catch (e) {
    // Two workers can pass the check above together; the partial unique index settles it.
    if (!dedupeKey || !isUniqueViolation(e)) throw e;
    const existing = await findDuplicate({ ...input, dedupeKey });
    if (existing) return { alert: await applyAttemptCount(existing, input), deduplicated: true };
    throw e;
  }

  await publishFamilyEvent(input.familyId, { type: "alert", payload: alert, ts: new Date().toISOString() });

  let childName = input.childName;
  if (!childName) {
    const child = await prisma.child.findUnique({ where: { id: input.childId }, select: { displayName: true } });
    childName = child?.displayName;
  }
  // Fire-and-forget by contract: notifyParentsOfAlert never throws and must not delay the agent's
  // 201. Awaited here only so tests can observe it; the cost is one in-memory fan-out.
  await notifyParentsOfAlert(input.familyId, alert, childName);
  return { alert, deduplicated: false };
}

/** Backwards-compatible wrapper for producers that do not use a dedupe key. */
export async function raiseAlert(input: RaiseAlertInput) {
  return (await raiseAlertOnce(input)).alert;
}
