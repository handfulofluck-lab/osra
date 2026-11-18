import { prisma } from "../db.js";
import { publishJson } from "../redis.js";
import { enqueueDeviceCommand } from "./deviceCommands.js";
import { hasEnforcingPlan, PREMIUM_FEATURES } from "./planGate.js";
import { siteNamesEnabled } from "./siteNames.js";

/** Parents keep their stored rules after a lapse; only the agent's enforcement projection is filtered. */
export async function filterAgentRules<T extends Record<string, unknown>>(childId: string, ruleSet: T): Promise<T> {
  const features = Object.keys(PREMIUM_FEATURES);
  if (!features.length) return ruleSet;
  const child = await prisma.child.findUnique({ where: { id: childId }, select: { familyId: true } });
  if (child && await hasEnforcingPlan(child.familyId)) return ruleSet;
  const filtered = { ...ruleSet };
  for (const feature of features) delete filtered[feature];
  return filtered;
}

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
    // ADR-0037 PR B3: rows from before the column read [] (the migration's default).
    appGroupRules: (row.appGroupRules as unknown[]) ?? [],
    alwaysAllowedApps: row.alwaysAllowedApps,
    bonusMinutesToday: row.bonusMinutesToday,
    /**
     * #830 gating: the agent may capture site names only when the server flag is on. It is part of the
     * rule projection because that is how the agent learns everything else it must honour, and an agent
     * that has not synced since the flag went on behaves like one on a server where it is off.
     */
    siteNames: siteNamesEnabled(),
    socialMonitoring: (row.socialMonitoring as Record<string, boolean>) ?? {},
    contactAllowlist: (row.contactAllowlist as string[]) ?? [],
    updatedAt: row.updatedAt,
    // Issue #475: the version the parent app compares against what the device has applied. Older rows
    // created before this column existed read 1, which matches the migration's default.
    rulesVersion: (row.rulesVersion as number) ?? 1,
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
  await publishJson(`child:${childId}:rules`, await filterAgentRules(childId, toApiRuleSet(row as unknown as Record<string, unknown>)));
  const devices = await prisma.device.findMany({ where: { childId }, select: { id: true } });
  for (const { id } of devices) {
    await enqueueDeviceCommand(id, "rules_updated", { reason });
  }
}
