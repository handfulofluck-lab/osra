import type { Prisma } from "@prisma/client";
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
}

export async function raiseAlert(input: RaiseAlertInput) {
  const alert = await prisma.alert.create({
    data: {
      childId: input.childId,
      deviceId: input.deviceId ?? undefined,
      severity: input.severity,
      category: input.category,
      title: input.title,
      body: input.body,
      metadata: (input.metadata ?? {}) as Prisma.InputJsonValue,
    },
  });
  await publishFamilyEvent(input.familyId, { type: "alert", payload: alert, ts: new Date().toISOString() });

  let childName = input.childName;
  if (!childName) {
    const child = await prisma.child.findUnique({ where: { id: input.childId }, select: { displayName: true } });
    childName = child?.displayName;
  }
  // Fire-and-forget by contract: notifyParentsOfAlert never throws and must not delay the agent's
  // 201. Awaited here only so tests can observe it; the cost is one in-memory fan-out.
  await notifyParentsOfAlert(input.familyId, alert, childName);
  return alert;
}
