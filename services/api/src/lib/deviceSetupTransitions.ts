import { prisma } from "../db.js";
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
  const { deduplicated } = await raiseAlertOnce({
    childId: device.childId,
    familyId: device.child.familyId,
    deviceId: device.id,
    severity: "warning",
    category: "tamper",
    title: "Phone setup needs attention",
    body: `${device.child.displayName}'s phone setup is not complete after 30 minutes${steps ? `: ${steps}` : "."}`,
    bodyKey: "alertBodySetupIncomplete",
    params: { childName: device.child.displayName, count: missing.length, steps },
    metadata: { type: "setup_incomplete", missing, pairedAt: device.pairedAt.toISOString() },
    dedupeKey: incompleteDedupeKey(device.id, device.pairedAt),
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
