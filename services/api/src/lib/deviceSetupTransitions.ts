import type { Prisma } from "@prisma/client";
import { prisma } from "../db.js";
import { publishFamilyEvent } from "../realtime/gateway.js";
import { raiseAlertOnce } from "./alerts.js";
import {
  completionDedupeKey,
  incompleteDedupeKey,
  requiredMissingGrants,
  setupIncompleteDue,
  SETUP_WINDOW_MS,
  type SetupDevice,
} from "./deviceSetup.js";

export interface SetupTransitionDevice extends SetupDevice {
  id: string;
  childId: string;
  model: string;
  child: { familyId: string; displayName: string };
}

export async function completeDeviceSetupIfReady(
  device: SetupTransitionDevice,
  capabilities: unknown,
  now: Date,
): Promise<boolean> {
  if (!device.pairedAt || requiredMissingGrants(capabilities)?.length !== 0) return false;
  // Migration 0046 marks existing devices complete at pairing; that backfill is not a new alert episode.
  if (device.setupCompletedAt?.getTime() === device.pairedAt.getTime()) return false;
  let claimedCompletion = false;
  if (!device.setupCompletedAt) {
    const claimed = await prisma.device.updateMany({
      where: { id: device.id, setupCompletedAt: null },
      data: { setupCompletedAt: now },
    });
    if ((claimed?.count ?? 0) === 0) return false;
    claimedCompletion = true;
  }
  try {
    const { deduplicated } = await raiseAlertOnce({
      childId: device.childId,
      familyId: device.child.familyId,
      deviceId: device.id,
      severity: "info",
      category: "tamper",
      title: "Phone is protected",
      body: `${device.child.displayName}'s phone is protected.`,
      bodyKey: "alertBodySetupCompleted",
      params: { childName: device.child.displayName },
      metadata: { type: "setup_complete", pairedAt: device.pairedAt.toISOString() },
      dedupeKey: completionDedupeKey(device.id, device.pairedAt),
      childName: device.child.displayName,
    });
    return !deduplicated;
  } catch (err) {
    // Only this attempt's claim may be rolled back. If that rollback also fails, the next all-ready
    // authenticated report retries the same deduped alert instead of exiting on the completed flag.
    if (claimedCompletion) {
      await prisma.device.updateMany({
        where: { id: device.id, setupCompletedAt: now },
        data: { setupCompletedAt: null },
      }).catch(() => undefined);
    }
    throw err;
  }
}

export interface SetupIncompleteResult {
  due: boolean;
  deduplicated: boolean;
}

export async function evaluateDeviceSetupIncomplete(
  device: SetupTransitionDevice,
  now: Date,
): Promise<SetupIncompleteResult> {
  if (!setupIncompleteDue(device, now) || !device.pairedAt) return { due: false, deduplicated: true };
  const missing = requiredMissingGrants(device.capabilities) ?? [];
  const steps = missing.join(", ");
  const title = "Phone setup needs attention";
  const body = `${device.child.displayName}'s phone setup is not complete after 30 minutes${steps ? `: ${steps}` : "."}`;
  const params = { childName: device.child.displayName, count: missing.length, steps };
  const metadata = { type: "setup_incomplete", missing, pairedAt: device.pairedAt.toISOString(), serverReminder: true };
  const dedupeKey = incompleteDedupeKey(device.id);

  // #1208: the phone may already have posted its immediate notice under the same key. That row IS the one
  // parent notice for this pairing: refresh what is still missing in place, publish it, and never page again.
  const existing = await prisma.alert.findFirst({ where: { deviceId: device.id, category: "tamper", dedupeKey } });
  if (existing) {
    const prev = (existing.metadata && typeof existing.metadata === "object" && !Array.isArray(existing.metadata)
      ? existing.metadata
      : {}) as Record<string, unknown>;
    const unchanged = prev.serverReminder === true && JSON.stringify(prev.missing ?? null) === JSON.stringify(missing);
    if (!unchanged && !existing.heldDuringSetup) {
      const updated = await prisma.alert.update({
        where: { id: existing.id },
        data: {
          title,
          body,
          metadata: { ...prev, ...metadata, bodyKey: "alertBodySetupIncomplete", bodyParams: params } as Prisma.InputJsonValue,
        },
      });
      await publishFamilyEvent(device.child.familyId, { type: "alert", payload: updated, ts: now.toISOString() });
    }
    return { due: true, deduplicated: true };
  }

  const { deduplicated } = await raiseAlertOnce({
    childId: device.childId,
    familyId: device.child.familyId,
    deviceId: device.id,
    severity: "warning",
    category: "tamper",
    title,
    body,
    bodyKey: "alertBodySetupIncomplete",
    params,
    metadata,
    dedupeKey,
    childName: device.child.displayName,
  });
  return { due: true, deduplicated };
}

export interface SetupRun {
  checked: number;
  alerted: string[];
}

export async function runDeviceSetupCheck(now: Date = new Date()): Promise<SetupRun> {
  const cutoff = new Date(now.getTime() - SETUP_WINDOW_MS);
  const devices = await prisma.device.findMany({
    where: { pairedAt: { not: null, lte: cutoff }, setupCompletedAt: null },
    select: {
      id: true,
      childId: true,
      platform: true,
      model: true,
      pairedAt: true,
      setupCompletedAt: true,
      capabilities: true,
      child: { select: { familyId: true, displayName: true } },
    },
  });
  const alerted: string[] = [];
  for (const device of devices) {
    const result = await evaluateDeviceSetupIncomplete(device, now);
    if (result.due && !result.deduplicated) alerted.push(device.id);
  }
  return { checked: devices.length, alerted };
}
