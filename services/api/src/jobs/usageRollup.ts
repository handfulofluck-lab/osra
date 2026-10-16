import { getRedis } from "../redis.js";
import { applyRetention, dayKey, rollupDay, utcDay, type RetentionResult } from "../lib/usageModel.js";

/**
 * Nightly usage rollup + retention (Phase 2c, ADR-0013). Same shape as the digest scheduler: an
 * hourly tick, a Redis `SET NX` claim per (job, day) so several API instances do not double-run, and
 * `JOBS_ENABLED=0` for deployments that call `runUsageRollupDue()` from an external cron.
 *
 * At `ROLLUP_HOUR_UTC` (default 02:00 UTC) it reconciles *yesterday's* `AppUsageDaily` rows from the
 * raw `ActivityEvent` log (idempotent — the rollup overwrites, ingestion-time increments are the
 * fast path) and then applies retention. Yesterday rather than today so a day is rolled up once its
 * agents have had time to upload the last batch.
 */

const TICK_MS = 60 * 60_000;
const CLAIM_TTL_SECONDS = 36 * 3600;
const MS_PER_DAY = 86_400_000;

export function rollupHourUtc(env: NodeJS.ProcessEnv = process.env): number {
  const h = Number(env.ROLLUP_HOUR_UTC ?? 2);
  return Number.isInteger(h) && h >= 0 && h <= 23 ? h : 2;
}

export interface RollupRun {
  day: string;
  rowsWritten: number;
  retention: RetentionResult;
}

/** Roll up one day and apply retention, unconditionally (used by tests and external cron). */
export async function runUsageRollup(day: Date, now: Date = new Date()): Promise<RollupRun> {
  const rowsWritten = await rollupDay(day);
  const retention = await applyRetention(now);
  return { day: dayKey(utcDay(day)), rowsWritten, retention };
}

/** The scheduler's tick: run once per UTC day, at the configured hour, claimed through Redis. */
export async function runUsageRollupDue(now: Date = new Date(), env: NodeJS.ProcessEnv = process.env): Promise<RollupRun | null> {
  if (now.getUTCHours() !== rollupHourUtc(env)) return null;
  const yesterday = new Date(utcDay(now).getTime() - MS_PER_DAY);
  const claim = await getRedis().set(`jobs:usage-rollup:${dayKey(yesterday)}`, now.toISOString(), "EX", CLAIM_TTL_SECONDS, "NX").catch(() => null);
  if (claim !== "OK") return null;
  const run = await runUsageRollup(yesterday, now);
  console.log(`[usage-rollup] ${run.day}: ${run.rowsWritten} rows reconciled; retention ${JSON.stringify(run.retention)}`);
  return run;
}

let timer: NodeJS.Timeout | null = null;

export function startUsageRollupScheduler(env: NodeJS.ProcessEnv = process.env): void {
  if (env.JOBS_ENABLED === "0" || env.NODE_ENV === "test") return;
  if (timer) return;
  const tick = () => runUsageRollupDue(new Date(), env).catch((err) => console.error("[usage-rollup] tick failed", err));
  timer = setInterval(tick, TICK_MS);
  timer.unref();
  console.log(`[usage-rollup] scheduler started (hour=${rollupHourUtc(env)}:00 UTC, tick=${TICK_MS / 60000}m)`);
}

export function stopUsageRollupScheduler(): void {
  if (timer) clearInterval(timer);
  timer = null;
}
