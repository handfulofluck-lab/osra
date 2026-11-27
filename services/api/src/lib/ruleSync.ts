import { prisma } from "../db.js";
import { publishJson } from "../redis.js";
import { enqueueDeviceCommand } from "./deviceCommands.js";
import { hasEnforcingPlan, PREMIUM_FEATURES } from "./planGate.js";
import { siteNamesEnabled } from "./siteNames.js";

/** Parents keep their stored rules after a lapse; only the agent's enforcement projection is filtered. */
/** F7: at most this many adults' names reach a child device, each cut to this many characters. */
export const AGENT_ADULT_NAMES_MAX = 4;
export const AGENT_ADULT_NAME_CHARS = 40;

/**
 * F7 (child screens C-01 / C-03): the family adults' display names the child app may show, such as
 * "Ask Karim". Owner first, then in join order. Names only, never ids, emails or roles. An empty list
 * means the client uses its "your parents" fallback; the client picks the wording with ICU plural/select.
 */
export async function agentAdultNames(familyId: string): Promise<string[]> {
  const parents = await prisma.parent.findMany({
    where: { familyId },
    select: { displayName: true, role: true, createdAt: true },
    orderBy: { createdAt: "asc" },
  });
  return [...(parents ?? [])]
    .sort((a, b) => (a.role === "owner" ? 0 : 1) - (b.role === "owner" ? 0 : 1))
    .map((p) => (typeof p.displayName === "string" ? p.displayName.trim().slice(0, AGENT_ADULT_NAME_CHARS).trim() : ""))
    .filter((name) => name.length > 0)
    .slice(0, AGENT_ADULT_NAMES_MAX);
}

/**
 * The agent's view of a ruleset: premium features dropped when the family has no enforcing plan, and
 * (F7) `adultNames` added. Every device-facing path (GET as a device, the Redis publish) goes through here.
 */
export async function filterAgentRules<T extends Record<string, unknown>>(childId: string, ruleSet: T): Promise<T> {
  const features = Object.keys(PREMIUM_FEATURES);
  const child = await prisma.child.findUnique({ where: { id: childId }, select: { familyId: true } });
  const filtered: Record<string, unknown> = { ...ruleSet };
  if (child?.familyId) {
    // A names lookup that fails must not stop rules reaching the phone: the client falls back to "your parents".
    filtered.adultNames = await agentAdultNames(child.familyId).catch(() => []);
  }
  if (features.length && !(child && await hasEnforcingPlan(child.familyId))) {
    for (const feature of features) delete filtered[feature];
  }
  return filtered as T;
}

/** Normalize legacy `"x"` socialMonitoring key to canonical `"twitter"` when `"twitter"` is absent (#1036). */
export function normalizeSocialMonitoring(raw: unknown): Record<string, boolean> {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  const out: Record<string, boolean> = { ...(raw as Record<string, boolean>) };
  if (!Object.hasOwn(out, "twitter") && Object.hasOwn(out, "x") && typeof out.x === "boolean") {
    out.twitter = out.x;
  }
  return out;
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
    socialMonitoring: normalizeSocialMonitoring(row.socialMonitoring),
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
