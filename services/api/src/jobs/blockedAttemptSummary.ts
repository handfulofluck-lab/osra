import type { Prisma } from "@prisma/client";
import { prisma } from "../db.js";
import { getRedis } from "../redis.js";
import { publishFamilyEvent } from "../realtime/gateway.js";
import { notifyParentsOfAlert } from "../lib/push/notify.js";
import { holdSocialPushBudget, nextPushDelivery, socialAlertWindowSeconds } from "../lib/socialAlertWindow.js";
import { BLOCKED_GROUP_CATEGORIES, blockedBudgetName, parseBlockedGroup } from "../lib/blockedAttemptWindow.js";

/**
 * #1222: the grouped half of the #1139 rule for blocked sites and apps. Every tick, a run whose budget was
 * spent and whose summary is due gets ONE summary push per (child, kind): the newest row pushes, older rows
 * of the same group are marked summarised without a second push. A summary closes the (child, kind) budget
 * for one more window, so attempts right after it are grouped into the next summary.
 */
export const BLOCKED_SUMMARY_TICK_MS = 30_000;
const LOOKBACK_MS = 24 * 60 * 60_000;

export interface BlockedSummaryPushed {
  alertId: string;
  childId: string;
  kind: string;
  delta: number;
  groupedAlertIds?: string[];
}

export async function runBlockedAttemptSummarySweep(
  now: Date = new Date(),
  env: NodeJS.ProcessEnv = process.env,
): Promise<{ checked: number; pushed: BlockedSummaryPushed[] }> {
  const nowMs = now.getTime();
  const nowIso = now.toISOString();
  const rows = await prisma.alert.findMany({
    where: {
      category: { in: [...BLOCKED_GROUP_CATEGORIES] },
      createdAt: { gte: new Date(nowMs - LOOKBACK_MS) },
      heldDuringSetup: false,
    },
    include: { child: { select: { familyId: true, displayName: true } } },
    orderBy: { createdAt: "desc" },
  });
  if (!Array.isArray(rows)) return { checked: 0, pushed: [] };

  const redis = getRedis();
  const windowSeconds = socialAlertWindowSeconds(env);
  const pushedByGroup = new Map<string, BlockedSummaryPushed>();
  const pushed: BlockedSummaryPushed[] = [];

  for (const row of rows) {
    const familyId = row.child?.familyId;
    if (!familyId) continue;
    const rawMeta = (row.metadata && typeof row.metadata === "object" && !Array.isArray(row.metadata)
      ? row.metadata
      : {}) as Record<string, unknown>;
    const group = parseBlockedGroup(rawMeta);
    if (!group?.summaryPending || !group.summaryDueAt) continue;
    const dueMs = Date.parse(group.summaryDueAt);
    if (!Number.isFinite(dueMs) || dueMs > nowMs) continue;
    const delta = (row.attemptCount ?? 1) - group.pushedCount;
    if (delta <= 0) continue;

    const claim = await redis
      .set(`jobs:blocked-summary:${row.id}:${group.summaryDueAt}`, nowIso, "EX", windowSeconds, "NX")
      .catch(() => null);
    if (claim !== "OK") continue;

    const groupKey = `${row.childId}:${group.kind}`;
    const groupPush = pushedByGroup.get(groupKey);
    const willPush = !groupPush;
    const nextGroup = {
      ...group,
      pushedCount: row.attemptCount ?? 1,
      summaryPending: false,
      summaryPushedAt: nowIso,
      lastPushAt: nowIso,
    };
    delete (nextGroup as { summaryDueAt?: string }).summaryDueAt;
    const nextMetadata: Record<string, unknown> = {
      ...rawMeta,
      blockGroup: nextGroup,
      summaryDelta: delta,
      // Delivery fields change only on the row whose push fires (#1139 parent contract).
      ...(willPush ? nextPushDelivery(rawMeta, nowIso) : { summaryGroupedInto: groupPush!.alertId }),
    };
    // Compare-and-set on the count: an attempt that lands during the sweep keeps its summary for the next tick.
    const res = await prisma.alert.updateMany({
      where: { id: row.id, attemptCount: row.attemptCount },
      data: { acknowledged: false, metadata: nextMetadata as Prisma.InputJsonValue },
    });
    if (res.count !== 1) continue;
    const updated = (await prisma.alert.findUnique({ where: { id: row.id } })) ?? {
      ...row,
      acknowledged: false,
      metadata: nextMetadata as Prisma.JsonValue,
    };
    await publishFamilyEvent(familyId, { type: "alert", payload: updated, ts: nowIso });
    if (!willPush) {
      groupPush!.delta += delta;
      (groupPush!.groupedAlertIds ??= []).push(row.id);
      continue;
    }
    await notifyParentsOfAlert(familyId, updated, row.child?.displayName ?? undefined);
    await holdSocialPushBudget(redis, row.childId, blockedBudgetName(group.kind), env);
    const item: BlockedSummaryPushed = { alertId: row.id, childId: row.childId, kind: group.kind, delta };
    pushedByGroup.set(groupKey, item);
    pushed.push(item);
  }

  if (pushed.length > 0 && env.NODE_ENV !== "test") {
    // Counts only: never a host, an app name or a child name.
    console.log(`[blocked-attempt-summary] sent ${pushed.length} summary push(es)`);
  }
  return { checked: rows.length, pushed };
}

let timer: NodeJS.Timeout | null = null;

export function startBlockedAttemptSummaryScheduler(env: NodeJS.ProcessEnv = process.env): void {
  if (env.JOBS_ENABLED === "0" || env.NODE_ENV === "test") return;
  if (timer) return;
  const tick = () =>
    runBlockedAttemptSummarySweep(new Date(), env).catch((err) => console.error("[blocked-attempt-summary] tick failed", err));
  timer = setInterval(tick, BLOCKED_SUMMARY_TICK_MS);
  timer.unref();
  console.log(`[blocked-attempt-summary] scheduler started (tick=${BLOCKED_SUMMARY_TICK_MS / 1000}s)`);
}

export function stopBlockedAttemptSummaryScheduler(): void {
  if (timer) clearInterval(timer);
  timer = null;
}
