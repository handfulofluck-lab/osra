import { prisma } from "../db.js";
import { publishJson } from "../redis.js";
import { enqueueDeviceCommand } from "./deviceCommands.js";

/** Map a flat Prisma RuleSet row to the nested API shape shared with agents. */
export function toApiRuleSet(row: Record<string, unknown>) {
  return {
    id: row.id,
    childId: row.childId,
    screenTime: {
      dailyLimitMinutes: row.dailyLimitMinutes,
      weekendLimitMinutes: row.weekendLimitMinutes,
      bedtimeStart: row.bedtimeStart,
      bedtimeEnd: row.bedtimeEnd,
      schoolHours: {
        start: row.schoolHoursStart,
        end: row.schoolHoursEnd,
        days: row.schoolDays,
      },
    },
    webFilter: {
      blockedCategories: row.blockedCategories,
      allowedDomains: row.allowedDomains,
      blockedDomains: row.blockedDomains,
      safeSearchEnforced: row.safeSearchEnforced,
      youtubeRestrictedMode: (row.youtubeRestrictedMode as string) ?? "strict",
    },
    appRules: row.appRules,
    routines: row.routines,
    alwaysAllowedApps: row.alwaysAllowedApps,
    bonusMinutesToday: row.bonusMinutesToday,
    socialMonitoring: (row.socialMonitoring as Record<string, boolean>) ?? {},
    contactAllowlist: (row.contactAllowlist as string[]) ?? [],
    updatedAt: row.updatedAt,
  };
}

/**
 * Publish the child's current ruleset to `child:<id>:rules` and enqueue
 * `rules_updated` on every device so agents re-fetch. Shared by the rules
 * routes, bonus grants (#10) and geofence routine auto-apply (#23).
 */
export async function publishChildRules(childId: string, reason = "rules_changed"): Promise<void> {
  const row = await prisma.ruleSet.findUnique({ where: { childId } });
  // No ruleset yet: agents keep serving defaults, so there is nothing to push.
  if (!row) return;
  await publishJson(`child:${childId}:rules`, toApiRuleSet(row as unknown as Record<string, unknown>));
  const devices = await prisma.device.findMany({ where: { childId }, select: { id: true } });
  for (const { id } of devices) {
    await enqueueDeviceCommand(id, "rules_updated", { reason });
  }
}
