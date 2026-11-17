import { prisma } from "../db.js";
import { getRedis } from "../redis.js";

/**
 * Issue #790: the sweep that removes a pairing claim's half-created device.
 *
 * `POST /v1/devices/pair/claims/:claimId/poll` creates the Device row on the parent's Allow, and
 * `middleware/pairedAt.ts` marks it paired on the first request the API accepts from it. A phone that
 * never gets that far — a wrong key, a planted fault, a bug in a new agent, or a parent's Allow on a
 * phone that was then closed — leaves a row nobody can see (every parent-facing read excludes
 * `pairedAt: null`) that would otherwise sit in the family for good. This sweep deletes those rows:
 * `pairedAt` null **and** `lastSeen` older than [PENDING_DEVICE_MINUTES].
 *
 * **Nothing is raised to the parent.** A device that never appeared in the app cannot be reported as
 * gone; an alert about a phone the parent has never seen is worse than silence, and it would arrive on
 * exactly the families whose pairing failed for an innocent reason (a flat battery during setup).
 *
 * `lastSeen` is the right clock, and it is the only one: the poll writes it when it creates the row, and
 * any later accepted request either refreshes it (`lib/pollCadence.ts`, telemetry, the location ping) or
 * is itself the request that clears pending. So the window is "30 minutes after the claim, unless the
 * phone answered" — a pending row can never have a fresh `lastSeen`, which is why this job cannot race
 * a healthy pairing in the direction that matters.
 *
 * Same shape as the other jobs: a tick, a Redis `SET NX` claim per device so several API instances do
 * not do the same delete, `JOBS_ENABLED=0` for deployments that call `runPendingDeviceSweep()` from an
 * external cron, and an exported runner the tests call.
 */

const TICK_MS = 5 * 60_000;

/** How long a device may stay pending. Long enough for a slow first boot, short enough that a broken
 * pairing does not linger in the family for a day. Thirty minutes matches the silence job's window, so a
 * parent who watched the pairing screen has one familiar number. */
export const PENDING_DEVICE_MINUTES = 30;

/**
 * One claim per device per sweep attempt, so two API instances never both delete the same row. Two ticks,
 * not an hour: a tick that dies between the claim and the delete must retry soon, and deletion is
 * idempotent, so the only thing a short claim costs is one extra statement in the losing instance.
 */
const CLAIM_TTL_SECONDS = 10 * 60;

export interface PendingSweepRun {
  /** Pending rows the sweep looked at (query result, before the per-device claim). */
  checked: number;
  /** Device ids actually deleted by this run. */
  deleted: string[];
}

export async function runPendingDeviceSweep(now: Date = new Date(), env: NodeJS.ProcessEnv = process.env): Promise<PendingSweepRun> {
  const cutoff = new Date(now.getTime() - PENDING_DEVICE_MINUTES * 60_000);
  const pending = await prisma.device.findMany({
    where: { pairedAt: null, lastSeen: { lt: cutoff } },
    select: { id: true },
  });
  const deleted: string[] = [];
  for (const device of pending) {
    // A store failure reads as "another instance may be on it": skipping is safe (the row is still
    // pending and still invisible; the next tick retries), while deleting without the claim would make
    // every instance do the same work and every log line claim it.
    const claim = await getRedis()
      .set(`jobs:pending-device:${device.id}`, now.toISOString(), "EX", CLAIM_TTL_SECONDS, "NX")
      .catch(() => null);
    if (claim !== "OK") continue;
    // `pairedAt: null` again in the DELETE, not only in the read above: a phone can clear pending
    // between the query and this statement, and the parent's device must not be deleted for having
    // answered a second too late. `deleteMany` rather than `delete` so that is a zero-row no-op instead
    // of a 404-style throw.
    const removed = await prisma.device.deleteMany({ where: { id: device.id, pairedAt: null } });
    if ((removed?.count ?? 0) > 0) deleted.push(device.id);
  }
  if (deleted.length > 0 && env.NODE_ENV !== "test") {
    // A count, not ids, models or child names: this log answers "did the sweep run", and nothing in it
    // becomes a record of what a family owned.
    console.log(`[pending-device] removed ${deleted.length} unproven pairing row(s)`);
  }
  return { checked: pending.length, deleted };
}

let timer: NodeJS.Timeout | null = null;

export function startPendingDeviceScheduler(env: NodeJS.ProcessEnv = process.env): void {
  if (env.JOBS_ENABLED === "0" || env.NODE_ENV === "test") return;
  if (timer) return;
  const tick = () => runPendingDeviceSweep(new Date(), env).catch((err) => console.error("[pending-device] tick failed", err));
  timer = setInterval(tick, TICK_MS);
  timer.unref();
  console.log(`[pending-device] scheduler started (after=${PENDING_DEVICE_MINUTES}m, tick=${TICK_MS / 60000}m)`);
}

export function stopPendingDeviceScheduler(): void {
  if (timer) clearInterval(timer);
  timer = null;
}
