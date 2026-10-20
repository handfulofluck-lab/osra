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
 * Raises an alert and says whether it was new. The duplicate path returns the row that already
 * exists and deliberately does not publish or push again — the parent has seen that alert.
 */
export async function raiseAlertOnce(
  input: RaiseAlertInput,
): Promise<{ alert: Alert; deduplicated: boolean }> {
  const dedupeKey = input.dedupeKey ?? null;

  if (dedupeKey) {
    const existing = await findDuplicate({ ...input, dedupeKey });
    if (existing) return { alert: existing, deduplicated: true };
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
      },
    });
  } catch (e) {
    // Two workers can pass the check above together; the partial unique index settles it.
    if (!dedupeKey || !isUniqueViolation(e)) throw e;
    const existing = await findDuplicate({ ...input, dedupeKey });
    if (existing) return { alert: existing, deduplicated: true };
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
