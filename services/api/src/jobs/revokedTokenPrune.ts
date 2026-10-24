import { prisma } from "../db.js";

/**
 * ADR-0032: delete single-logout records whose token has already expired.
 *
 * `RevokedToken` is the durable half of a single logout (`revoked:token:<jti>` is the cache). A row
 * records the token's own end in `expiresAt`, which is never later than the 8-day Redis key, so once
 * that instant has passed the row can never change a decision: the token it revokes is past its
 * 7-day lifetime and would be refused by the JWT layer anyway. Deleting it keeps the table bounded
 * by "sessions revoked in the last 8 days" instead of by every logout the product has ever served.
 *
 * The comparison instant is bound from JS, never the server's `NOW()` — the lesson from #53: a
 * Postgres session in a different time zone must not move a retention boundary.
 *
 * Idempotent and safe on several instances at once: one `deleteMany` with no claim, so a duplicate
 * tick deletes zero rows. That is also why it needs no Redis, unlike the digest and rollup jobs.
 */

const TICK_MS = 24 * 60 * 60_000;

export interface RevokedTokenPruneRun {
  deleted: number;
}

export async function runRevokedTokenPrune(now: Date = new Date()): Promise<RevokedTokenPruneRun> {
  const { count } = await prisma.revokedToken.deleteMany({ where: { expiresAt: { lt: now } } });
  return { deleted: count };
}

let timer: NodeJS.Timeout | null = null;

export function startRevokedTokenPruneScheduler(env: NodeJS.ProcessEnv = process.env): void {
  if (env.JOBS_ENABLED === "0" || env.NODE_ENV === "test") return;
  if (timer) return;
  const tick = () =>
    runRevokedTokenPrune()
      .then((run) => {
        // Silent when there was nothing to delete: an unconditional daily line that says "0 rows" is
        // noise. A non-zero run is worth a line, because it is a retention decision somebody may ask
        // about later.
        if (run.deleted > 0) console.log(`[revoked-token] prune: ${run.deleted} expired single-logout rows deleted`);
      })
      .catch((err) => console.error("[revoked-token] prune tick failed", err));
  timer = setInterval(tick, TICK_MS);
  timer.unref();
  console.log(`[revoked-token] prune scheduler started (tick=${TICK_MS / 3_600_000}h)`);
}

export function stopRevokedTokenPruneScheduler(): void {
  if (timer) clearInterval(timer);
  timer = null;
}
