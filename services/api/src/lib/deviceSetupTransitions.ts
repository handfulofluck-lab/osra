import type { Prisma } from "@prisma/client";
import { prisma } from "../db.js";
import { publishFamilyEvent } from "../realtime/gateway.js";
import { getRedis } from "../redis.js";
import { nextPushDelivery } from "./socialAlertWindow.js";
import {
  isUniqueViolation,
  newAlertDispatch,
  raiseAlertOnce,
  storeAlertOnce,
  type AlertStore,
  type RaiseAlertInput,
  type StoredAlert,
} from "./alerts.js";
import {
  completionDedupeKey,
  incompleteDedupeKey,
  legacyIncompleteDedupeKey,
  requiredMissingGrants,
  setupIncompleteDue,
  setupNoticeKeys,
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

/** What the locked Device row says right now: the completion latch and the server-validated grants. */
export interface SetupLockState {
  setupCompletedAt: Date | null;
  capabilities: unknown;
  capabilitiesReportedAt: Date | null;
}

const SETUP_TX = { maxWait: 5_000, timeout: 20_000 } as const;
const NO_DISPATCH = async () => undefined;

/**
 * Codex (#1230, finding 2): a setup notice must never be written after completion has committed. The
 * eligibility check and the write run in one short transaction holding the Device row with FOR NO KEY UPDATE:
 * the completion claim (an UPDATE of setupCompletedAt) waits for us, and if completion committed first we see
 * it. NO KEY UPDATE, not UPDATE, so the alert insert's foreign-key check (KEY SHARE) on the row is not blocked.
 * osra-security#87: every durable read and write in `fn` uses the `tx` it is given, and anything that
 * publishes or pushes is returned by `fn` and run by the caller after commit. Returns null when the device
 * is gone.
 */
export async function withSetupLock<T>(
  deviceId: string,
  fn: (tx: Prisma.TransactionClient, state: SetupLockState) => Promise<T>,
): Promise<T | null> {
  return prisma.$transaction(async (tx) => {
    const rows = await tx.$queryRaw<SetupLockState[]>`
      SELECT "setupCompletedAt", "capabilities", "capabilitiesReportedAt" FROM "Device" WHERE "id" = ${deviceId} FOR NO KEY UPDATE`;
    if (!rows?.[0]) return null;
    return fn(tx, {
      setupCompletedAt: rows[0].setupCompletedAt ?? null,
      capabilities: rows[0].capabilities ?? null,
      capabilitiesReportedAt: rows[0].capabilitiesReportedAt ?? null,
    });
  }, SETUP_TX);
}

/** withSetupLock for writers that only act while first setup is still open; null once it is complete. */
export async function withSetupOpen<T>(
  deviceId: string,
  fn: (tx: Prisma.TransactionClient, state: SetupLockState) => Promise<T>,
): Promise<T | null> {
  return withSetupLock(deviceId, async (tx, state) => (state.setupCompletedAt ? null : fn(tx, state)));
}

/** The pairing's one setup notice, under the shared key or the pre-#1208 server key. */
export async function findSetupNotice(db: AlertStore, deviceId: string, pairedAt: Date | null | undefined) {
  return db.alert.findFirst({
    where: { deviceId, category: "tamper", dedupeKey: { in: setupNoticeKeys(deviceId, pairedAt) } },
  });
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

  // #1208: the phone may already have posted its immediate notice under the same key, or (Codex, finding 1)
  // this pairing was reminded before the upgrade under the old per-episode key. Either row IS the one parent
  // notice: refresh what is still missing in place when it changed, and never page again.
  const legacyKey = legacyIncompleteDedupeKey(device.id, device.pairedAt);
  let outcome: StoredAlert | null;
  try {
    outcome = await withSetupOpen(device.id, async (tx): Promise<StoredAlert> => {
      const existing = await findSetupNotice(tx, device.id, device.pairedAt);
      if (existing) {
        const prev = (existing.metadata && typeof existing.metadata === "object" && !Array.isArray(existing.metadata)
          ? existing.metadata
          : {}) as Record<string, unknown>;
        const serverRow = prev.serverReminder === true || existing.dedupeKey === legacyKey;
        const unchanged = serverRow && JSON.stringify(prev.missing ?? null) === JSON.stringify(missing);
        if (unchanged || existing.heldDuringSetup) return { alert: existing, deduplicated: true, dispatch: NO_DISPATCH };
        const updated = await tx.alert.update({
          where: { id: existing.id },
          data: {
            title,
            body,
            metadata: { ...prev, ...metadata, bodyKey: "alertBodySetupIncomplete", bodyParams: params } as Prisma.InputJsonValue,
          },
        });
        return {
          alert: updated,
          deduplicated: true,
          dispatch: async () => {
            await publishFamilyEvent(device.child.familyId, { type: "alert", payload: updated, ts: now.toISOString() });
          },
        };
      }
      return storeAlertOnce({
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
      }, tx);
    });
  } catch (err) {
    // The shared key's unique index settled a race we did not see under the lock: that row is the notice.
    if (isUniqueViolation(err)) return { due: true, deduplicated: true };
    throw err;
  }
  // Completion committed before we could write: no reminder at all.
  if (!outcome) return { due: false, deduplicated: true };
  await outcome.dispatch();
  return { due: true, deduplicated: outcome.deduplicated };
}

export type PhoneSetupNoticeOutcome = StoredAlert & { upgrade: boolean };

/** The notice may be ahead of the telemetry that explains it: the phone should send it again shortly. */
export const AWAIT_REPORT = "await_report" as const;
/** How long a completed pairing's notice waits for a capabilities report before it is treated as stale. */
export const SETUP_NOTICE_REPORT_WAIT_MS = 10 * 60_000;
export const setupNoticeWaitKey = (deviceId: string) => `setup_notice_wait:${deviceId}`;

/** When this pairing's pending notice was first seen (kept for an hour), or null when Redis cannot say. */
async function noticeFirstSeen(deviceId: string, now: Date): Promise<number | null> {
  try {
    const redis = getRedis();
    const key = setupNoticeWaitKey(deviceId);
    await redis.set(key, String(now.getTime()), "EX", 3600, "NX");
    const ms = Number.parseInt((await redis.get(key)) ?? "", 10);
    return Number.isFinite(ms) ? ms : null;
  } catch {
    return null;
  }
}

async function clearNoticeWait(deviceId: string): Promise<void> {
  try {
    await getRedis().del(setupNoticeWaitKey(deviceId));
  } catch {
    /* the key expires on its own */
  }
}

function metadataObject(raw: unknown): Record<string, unknown> {
  return raw && typeof raw === "object" && !Array.isArray(raw) ? (raw as Record<string, unknown>) : {};
}

/**
 * #1208 + Codex (osra-security#82): the phone's own setup notice, decided under the Device row lock.
 * - First setup still open: the pairing's one notice (shared or pre-#1208 key) dedupes it; otherwise it is stored.
 * - Setup complete and the server-validated grants show a required grant missing (an app upgrade added one):
 *   a real notice. It is stored under the shared key, pushed once, and the completion latch is left set. A row
 *   from the first-setup episode (written before completion) is re-raised in place, because the unique key
 *   allows one row; a row written after completion is this episode already and dedupes. Either way the upgrade
 *   carries its own server-issued delivery identity (pushDeliveryId/Seq), so a parent phone that already showed
 *   the first notice shows the upgrade once, and a duplicate wake for it stays quiet (Codex, 7204850059 point 2).
 * - Setup complete and every required grant granted (Codex, 7204850059 point 1): the phone can enqueue the notice
 *   from its live grant check before the telemetry that reports the missing grant is stored. Until a capabilities
 *   report arrives after the notice was first seen, the answer is AWAIT_REPORT (retryable), not a terminal drop.
 *   A report after that time showing every grant, or no report within SETUP_NOTICE_REPORT_WAIT_MS, makes it a
 *   stale first-setup retry: null, nothing written. Without Redis the old terminal drop applies.
 * Side effects run after commit (osra-security#87).
 */
export async function raisePhoneSetupNotice(
  deviceId: string,
  pairedAt: Date | null | undefined,
  input: RaiseAlertInput,
  now: Date = new Date(),
): Promise<PhoneSetupNoticeOutcome | null | typeof AWAIT_REPORT> {
  let outcome: PhoneSetupNoticeOutcome | null | typeof AWAIT_REPORT;
  let clearWait = false;
  const nowIso = now.toISOString();
  try {
    outcome = await withSetupLock(deviceId, async (tx, state): Promise<PhoneSetupNoticeOutcome | null | typeof AWAIT_REPORT> => {
      if (!state.setupCompletedAt) {
        const existing = await findSetupNotice(tx, deviceId, pairedAt);
        if (existing) return { alert: existing, deduplicated: true, dispatch: NO_DISPATCH, upgrade: false };
        return { ...(await storeAlertOnce(input, tx)), upgrade: false };
      }
      if ((requiredMissingGrants(state.capabilities)?.length ?? 0) === 0) {
        const firstSeen = await noticeFirstSeen(deviceId, now);
        const reportedAt = state.capabilitiesReportedAt ? new Date(state.capabilitiesReportedAt).getTime() : null;
        if (firstSeen !== null && (reportedAt === null || reportedAt < firstSeen) &&
            now.getTime() - firstSeen < SETUP_NOTICE_REPORT_WAIT_MS) {
          return AWAIT_REPORT;
        }
        clearWait = true;
        return null;
      }
      clearWait = true;
      const sharedKey = incompleteDedupeKey(deviceId);
      // Codex (osra-security#82, 7205450617 point 2): the pairing's one notice may still live under the pre-#1208
      // per-episode key. Look it up by both keys, so a legacy row is re-raised in place (same id, same key) instead
      // of a second row being stored under the shared key.
      const existing = await findSetupNotice(tx, deviceId, pairedAt);
      if (existing && new Date(existing.createdAt).getTime() >= new Date(state.setupCompletedAt).getTime()) {
        return { alert: existing, deduplicated: true, dispatch: NO_DISPATCH, upgrade: true };
      }
      if (existing) {
        const reraised = await tx.alert.update({
          where: { id: existing.id },
          data: {
            severity: input.severity,
            title: input.title,
            body: input.body,
            metadata: { ...(input.metadata ?? {}), ...nextPushDelivery(metadataObject(existing.metadata), nowIso) } as Prisma.InputJsonValue,
            acknowledged: false,
            heldDuringSetup: false,
            createdAt: now,
          },
        });
        return { alert: reraised, deduplicated: false, dispatch: newAlertDispatch(input, reraised), upgrade: true };
      }
      const stored = await storeAlertOnce({
        ...input,
        dedupeKey: sharedKey,
        heldDuringSetup: false,
        metadata: { ...(input.metadata ?? {}), ...nextPushDelivery(null, nowIso) },
      }, tx);
      return { ...stored, upgrade: true };
    });
  } catch (err) {
    if (!isUniqueViolation(err)) throw err;
    // Another request stored this pairing's notice between our read and write; it is the one notice.
    const existing = await findSetupNotice(prisma, deviceId, pairedAt);
    if (!existing) throw err;
    return { alert: existing, deduplicated: true, dispatch: NO_DISPATCH, upgrade: false };
  }
  if (clearWait) await clearNoticeWait(deviceId);
  if (outcome && outcome !== AWAIT_REPORT) await outcome.dispatch();
  return outcome;
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
