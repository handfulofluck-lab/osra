import type { Prisma } from "@prisma/client";
import { prisma } from "../db.js";
import { getRedis } from "../redis.js";
import { publishFamilyEvent } from "../realtime/gateway.js";
import { notifyParentsOfAlert } from "../lib/push/notify.js";
import {
  SOCIAL_ALERT_WINDOW_MS,
  SOCIAL_ALERT_WINDOW_SECONDS,
  parseSocialWindowMetadata,
  type SocialWindowRedisState,
} from "../lib/socialAlertWindow.js";

/**
 * Window-close summary push scheduler for throttled social alerts (issue #1029).
 *
 * Mirrors `jobs/pendingDevices.ts` and `jobs/deviceSilence.ts`:
 * - Polls on a short interval (`SOCIAL_SUMMARY_TICK_MS = 30 s`) for per-contact social alert
 *   windows whose `windowEndsAt` has elapsed with `flaggedCount > pushedCount`.
 * - Uses a Redis `SET NX` claim per `(alertId, windowEndsAt)` so multiple API instances never send
 *   duplicate summary pushes.
 * - Sends at most one lock-screen-safe summary push per closed window (via `notifyParentsOfAlert`,
 *   which emits zero message text and zero contact names), updates the alert row in place, and
 *   opens a fresh 10-minute window on that push so a parent never receives more than one push per
 *   10 minutes unless severity escalates.
 * - Honors `JOBS_ENABLED=0` and `NODE_ENV=test`; exports `runSocialAlertSummarySweep()` for tests.
 */

export const SOCIAL_SUMMARY_TICK_MS = 30_000;

/**
 * Atomic conditional rollover for the per-contact Redis throttle key (Redis 5.0.14 compatible;
 * Codex review of #1033). Writes the post-summary window ONLY when the key is absent (expired)
 * or still belongs to this same alert; if a newer window (`__pending__` or a newer `alertId`)
 * already claimed the key before a delayed sweep ran, leaves the newer window untouched.
 */
export const SOCIAL_WINDOW_ROLLOVER_SCRIPT = `
local cur = redis.call('GET', KEYS[1])
if (not cur) or string.find(cur, ARGV[1], 1, true) then
  redis.call('SET', KEYS[1], ARGV[2], 'EX', tonumber(ARGV[3]))
  return 1
end
return 0
`;
const LOOKBACK_MS = 24 * 60 * 60_000;

export interface SocialSummaryPushedItem {
  alertId: string;
  childId: string;
  app: string;
  delta: number;
}

export interface SocialSummarySweepRun {
  checked: number;
  pushed: SocialSummaryPushedItem[];
}

export async function runSocialAlertSummarySweep(
  now: Date = new Date(),
  env: NodeJS.ProcessEnv = process.env,
): Promise<SocialSummarySweepRun> {
  const nowMs = now.getTime();
  const nowIso = now.toISOString();
  const lookback = new Date(nowMs - LOOKBACK_MS);

  const candidates = await prisma.alert.findMany({
    where: {
      category: { in: ["social_concern", "gaming_chat"] },
      createdAt: { gte: lookback },
    },
    include: {
      child: { select: { familyId: true, displayName: true } },
    },
  });

  if (!Array.isArray(candidates)) {
    return { checked: 0, pushed: [] };
  }

  const pushed: SocialSummaryPushedItem[] = [];
  const redis = getRedis();

  for (const row of candidates) {
    const rawMeta = (row.metadata && typeof row.metadata === "object" && !Array.isArray(row.metadata)
      ? row.metadata
      : null) as Record<string, unknown> | null;
    const meta = parseSocialWindowMetadata(rawMeta);
    if (!meta || !meta.summaryPending) continue;
    const endsAtMs = Date.parse(meta.windowEndsAt);
    if (!Number.isFinite(endsAtMs) || endsAtMs > nowMs) continue;
    const delta = meta.flaggedCount - meta.pushedCount;
    if (delta <= 0) continue;

    // Multi-instance guard: only one API instance may emit the summary push for this window close.
    const claimKey = `jobs:social-summary:${row.id}:${meta.windowEndsAt}`;
    const claim = await redis.set(claimKey, nowIso, "EX", SOCIAL_ALERT_WINDOW_SECONDS, "NX").catch(() => null);
    if (claim !== "OK") continue;

    const childInfo = (row as { child?: { familyId?: string; displayName?: string | null } | null }).child;
    const familyId = childInfo?.familyId;
    if (!familyId) continue;

    const nextWindowEndsAt = new Date(nowMs + SOCIAL_ALERT_WINDOW_MS).toISOString();
    const nextMetadata: Record<string, unknown> = {
      ...(rawMeta ?? {}),
      pushedCount: meta.flaggedCount,
      summaryPending: false,
      summaryPushed: true,
      summaryDelta: delta,
      summaryPushedAt: nowIso,
      windowStartedAt: nowIso,
      windowEndsAt: nextWindowEndsAt,
    };

    const updated = await prisma.alert.update({
      where: { id: row.id },
      data: {
        acknowledged: false,
        metadata: nextMetadata as Prisma.InputJsonValue,
      },
    });
    const updatedAlert = updated ?? {
      ...row,
      acknowledged: false,
      metadata: nextMetadata,
    };

    // Atomically start the next 10-minute window at this summary push ONLY if no newer window has
    // already claimed this contact's throttle key (Codex #1033 review). If a delayed sweep runs
    // after a newer alert opened, the newer window stays active and untouched.
    if (meta.contactKey) {
      const throttleKey = `social:alert:${row.childId}:${meta.app.trim().toLowerCase()}:${meta.contactKey}`;
      const nextState: SocialWindowRedisState = {
        alertId: row.id,
        windowStartedAt: nowIso,
        windowEndsAt: nextWindowEndsAt,
        pushedSeverity: meta.pushedSeverity,
      };
      const payload = JSON.stringify(nextState);
      const expectedToken = `"alertId":${JSON.stringify(row.id)}`;
      const evalRes = await redis
        .eval(SOCIAL_WINDOW_ROLLOVER_SCRIPT, 1, throttleKey, expectedToken, payload, String(SOCIAL_ALERT_WINDOW_SECONDS))
        .catch(() => null);
      if (evalRes !== 0 && evalRes !== 1) {
        // Fallback for unit-test mocks that don't stub `eval`: still atomic NX, never overwrites a newer key.
        await redis.set(throttleKey, payload, "EX", SOCIAL_ALERT_WINDOW_SECONDS, "NX").catch(() => undefined);
      }
    }

    await publishFamilyEvent(familyId, { type: "alert", payload: updatedAlert, ts: nowIso });
    await notifyParentsOfAlert(familyId, updatedAlert, childInfo?.displayName ?? undefined);
    pushed.push({ alertId: row.id, childId: row.childId, app: meta.app, delta });
  }

  if (pushed.length > 0 && env.NODE_ENV !== "test") {
    // Count only — never log contact names, message text, or child names.
    console.log(`[social-alert-summary] sent ${pushed.length} window-close summary push(es)`);
  }

  return { checked: candidates.length, pushed };
}

let timer: NodeJS.Timeout | null = null;

export function startSocialAlertSummaryScheduler(env: NodeJS.ProcessEnv = process.env): void {
  if (env.JOBS_ENABLED === "0" || env.NODE_ENV === "test") return;
  if (timer) return;
  const tick = () =>
    runSocialAlertSummarySweep(new Date(), env).catch((err) =>
      console.error("[social-alert-summary] tick failed", err),
    );
  timer = setInterval(tick, SOCIAL_SUMMARY_TICK_MS);
  timer.unref();
  console.log(`[social-alert-summary] scheduler started (tick=${SOCIAL_SUMMARY_TICK_MS / 1000}s)`);
}

export function stopSocialAlertSummaryScheduler(): void {
  if (timer) clearInterval(timer);
  timer = null;
}