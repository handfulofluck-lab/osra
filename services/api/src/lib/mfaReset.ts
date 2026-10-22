import { createHash, randomInt, timingSafeEqual } from "node:crypto";
import { prisma } from "../db.js";

/**
 * ADR-0031 state machine, shared by the routes and the expiry job.
 *
 * ```
 *   requested ──confirm──▶ mailbox_confirmed ──witness/approve──▶ witness_passed ──complete──▶ completed
 *       │                        │                                    │
 *       │                        └──24 h without a witness──▶ expired  └──window open, complete refused
 *       └──24 h without a click──▶ expired
 *   from requested / mailbox_confirmed / witness_passed:
 *       a successful /login ─▶ cancelled_by_signin · cancel link ─▶ cancelled_by_link
 *       another owner/co-parent ─▶ cancelled_by_parent
 *   five wrong device codes ─▶ too_many_attempts
 * ```
 *
 * `no_witness` is in the vocabulary because the ADR names it, but it is never a row: claim 7 refuses
 * at request time and stores nothing, so it is absent from `OPEN_RESET_STATES` and from every write.
 *
 * The device code is eight digits, valid ten minutes, and only its SHA-256 is stored (claim 6). The
 * plaintext exists in the `show_reset_code` command payload and is cleared when the device
 * acknowledges the command, when the command expires (the expiry job sweeps it) or when the witness
 * passes — whichever comes first.
 */

export const MFA_RESET_STATES = [
  "requested",
  "mailbox_confirmed",
  "witness_passed",
  "completed",
  "cancelled_by_signin",
  "cancelled_by_link",
  "cancelled_by_parent",
  "expired",
  "too_many_attempts",
  "no_witness",
] as const;

export type MfaResetState = (typeof MFA_RESET_STATES)[number];

/** A request that is still moving; the set "one open request per parent" counts and sign-in cancels. */
export const OPEN_RESET_STATES = ["requested", "mailbox_confirmed", "witness_passed"] as const;

/** The mailbox link: single use, 30 minutes (decision 2.2). */
export const MFA_RESET_MAILBOX_TTL_SECONDS = 30 * 60;

/** The witness step must land within 24 hours of the mailbox confirmation (decision 3). */
export const MFA_RESET_WITNESS_DEADLINE_MS = 24 * 60 * 60 * 1000;

/** The window that starts when the witness passes (decision 2.4). */
export const MFA_RESET_WINDOW_MS = 72 * 60 * 60 * 1000;

/** The device code's life (decision 2.3). */
export const MFA_RESET_CODE_LENGTH = 8;
export const MFA_RESET_CODE_TTL_SECONDS = 10 * 60;

/** Five wrong codes end the request (decision 2.3). */
export const MFA_RESET_MAX_CODE_ATTEMPTS = 5;

/** At most three requests per parent in any 30 days, and one open at a time (decision 7). */
export const MFA_RESET_MAX_PER_WINDOW = 3;
export const MFA_RESET_REQUEST_WINDOW_MS = 30 * 24 * 60 * 60 * 1000;

/** Rows are deleted 12 months after the outcome (decision 8). */
export const MFA_RESET_RETENTION_MS = 365 * 24 * 60 * 60 * 1000;

/** A uniformly random eight-digit code, zero-padded, so `00000001` is as likely as any other. */
export function generateResetCode(): string {
  return randomInt(0, 10 ** MFA_RESET_CODE_LENGTH).toString().padStart(MFA_RESET_CODE_LENGTH, "0");
}

/** The only form of the code that is stored (decision 7). */
export function hashResetCode(code: string): string {
  return createHash("sha256").update(code).digest("hex");
}

/** Constant-time match of a submitted code against a stored hash; a missing hash never matches. */
export function resetCodeMatches(code: string, codeHash: string | null): boolean {
  if (!codeHash) return false;
  const submitted = Buffer.from(hashResetCode(code), "hex");
  const stored = Buffer.from(codeHash, "hex");
  return submitted.length === stored.length && timingSafeEqual(submitted, stored);
}

/** The 72-hour window opened by a passed witness. */
export function resetWindowEndsAt(witnessAt: Date): Date {
  return new Date(witnessAt.getTime() + MFA_RESET_WINDOW_MS);
}

/**
 * Drop the plaintext code from every `show_reset_code` row of one request.
 *
 * A row whose payload no longer holds the key does not match `->>` and is left alone, so this is
 * cheap to call on every path that ends a request.
 */
export async function clearResetCodePayloads(requestId: string): Promise<number> {
  return prisma.$executeRaw`
    UPDATE "DeviceCommand"
    SET "payload" = '{}'::jsonb
    WHERE "type" = 'show_reset_code' AND "payload"->>'requestId' = ${requestId}`;
}
