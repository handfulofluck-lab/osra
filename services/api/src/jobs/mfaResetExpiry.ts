import { prisma } from "../db.js";
import {
  MFA_RESET_RETENTION_MS,
  MFA_RESET_WITNESS_DEADLINE_MS,
} from "../lib/mfaReset.js";

/**
 * ADR-0031 expiry: the one clock the reset does not carry in its own row.
 *
 * Three sweeps, all idempotent `updateMany`/`DELETE`s so several API instances can run the tick at the
 * same time without double-acting and without a Redis claim:
 *
 *  1. `mailbox_confirmed` past 24 hours from `emailConfirmedAt` → `expired` (decision 3, "Expiry").
 *  2. `requested` past 24 hours from `createdAt` → `expired`. The ADR's clock starts at the mailbox
 *     confirmation, which a request whose link was never clicked never reaches; without this the row
 *     would sit in the open set for ever and block the parent's next request (decision 7, one open
 *     request per parent). Twenty-four hours is the same bound the ADR chose for the other half.
 *  3. `outcomeAt` older than 12 months → deleted (decision 8, retention).
 *
 * It also clears the plaintext device code from any `show_reset_code` command whose row has expired
 * (claim 6). Ack and a passed/cancelled witness clear it earlier; this is the backstop for a phone
 * that never acknowledged.
 *
 * It deliberately does **not** send the 24-hour reminder (ADR-0031 decision 4, "24 hours before the
 * window ends"): the email and push templates are not built in this change, and inventing a sender
 * here would make the job look finished when the notification half is not.
 */

const TICK_MS = 5 * 60_000;

export interface MfaResetExpiryRun {
  /** mailbox_confirmed requests past their 24-hour witness deadline. */
  witnessExpired: number;
  /** requested requests whose mailbox link was never clicked within 24 hours. */
  mailboxExpired: number;
  /** show_reset_code payloads cleared because their command expired. */
  codesCleared: number;
  /** rows deleted by the 12-month retention rule. */
  retentionDeleted: number;
}

export async function runMfaResetExpiry(now: Date = new Date()): Promise<MfaResetExpiryRun> {
  // The sweep compares instants bound from JS, never the server's NOW() — the lesson from #53.
  const witnessCutoff = new Date(now.getTime() - MFA_RESET_WITNESS_DEADLINE_MS);
  const witness = await prisma.mfaResetRequest.updateMany({
    where: { state: "mailbox_confirmed", emailConfirmedAt: { lte: witnessCutoff } },
    data: { state: "expired", outcomeAt: now },
  });
  const mailbox = await prisma.mfaResetRequest.updateMany({
    where: { state: "requested", createdAt: { lte: witnessCutoff } },
    data: { state: "expired", outcomeAt: now },
  });
  // `payload ? 'code'` (jsonb key existence) keeps this from rewriting rows that are already clear,
  // so the sweep is bounded by the number of live codes, not by the history of the table.
  const cleared = await prisma.$executeRaw`
    UPDATE "DeviceCommand"
    SET "payload" = '{}'::jsonb
    WHERE "type" = 'show_reset_code' AND "expiresAt" <= ${now} AND "payload" ? 'code'`;
  const retentionCutoff = new Date(now.getTime() - MFA_RESET_RETENTION_MS);
  const retained = await prisma.mfaResetRequest.deleteMany({
    where: { outcomeAt: { lt: retentionCutoff } },
  });
  return {
    witnessExpired: witness.count,
    mailboxExpired: mailbox.count,
    codesCleared: Number(cleared),
    retentionDeleted: retained.count,
  };
}

let timer: NodeJS.Timeout | null = null;

export function startMfaResetExpiryScheduler(env: NodeJS.ProcessEnv = process.env): void {
  if (env.JOBS_ENABLED === "0" || env.NODE_ENV === "test") return;
  if (timer) return;
  const tick = () => runMfaResetExpiry().catch((err) => console.error("[mfa-reset] expiry tick failed", err));
  timer = setInterval(tick, TICK_MS);
  timer.unref();
  console.log(`[mfa-reset] expiry scheduler started (tick=${TICK_MS / 60000}m; the 24-hour reminder is not sent — templates deferred)`);
}

export function stopMfaResetExpiryScheduler(): void {
  if (timer) clearInterval(timer);
  timer = null;
}
