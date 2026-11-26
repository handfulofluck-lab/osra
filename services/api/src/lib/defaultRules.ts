import { DEFAULT_BLOCKED_CATEGORIES } from "@familyshield/shared-types";

/**
 * Default ruleset applied to every new child (Feature #1); categories come from shared-types.
 *
 * #1172: no routine runs until a parent turns it on. Bedtime is saved off (its times stay as the suggestion
 * the switch turns on) and School hours has no days, which every agent already reads as "no school window".
 */
export const DEFAULT_RULESET = {
  screenTime: {
    dailyLimitMinutes: 180,
    weekendLimitMinutes: 300,
    bedtimeStart: "21:00",
    bedtimeEnd: "07:00",
    bedtimeEnabled: false,
    schoolHours: { start: "08:00", end: "15:00", days: [] as number[] },
  },
  webFilter: {
    blockedCategories: [...DEFAULT_BLOCKED_CATEGORIES],
    allowedDomains: [],
    blockedDomains: [],
    safeSearchEnforced: true,
    youtubeRestrictedMode: "strict",
  },
  appRules: [],
  routines: [],
  appGroupRules: [] as { groupId: string; action: "block" }[],
  alwaysAllowedApps: [],
  bonusMinutesToday: 0,
  socialMonitoring: {
    whatsapp: true,
    instagram: true,
    tiktok: true,
    snapchat: true,
    twitter: true,
    discord: true,
    roblox: true,
    line: true,
    youtube: true,
    telegram: true,
    reddit: true,
    messenger: true,
  } as Record<string, boolean>,
  contactAllowlist: [] as string[],
};

/** Flat Prisma RuleSet row carrying the full default ruleset for a newly created child. */
export function defaultRuleSetRow(childId: string) {
  return {
    childId,
    dailyLimitMinutes: DEFAULT_RULESET.screenTime.dailyLimitMinutes,
    weekendLimitMinutes: DEFAULT_RULESET.screenTime.weekendLimitMinutes,
    bedtimeStart: DEFAULT_RULESET.screenTime.bedtimeStart,
    bedtimeEnd: DEFAULT_RULESET.screenTime.bedtimeEnd,
    bedtimeEnabled: DEFAULT_RULESET.screenTime.bedtimeEnabled,
    schoolHoursStart: DEFAULT_RULESET.screenTime.schoolHours.start,
    schoolHoursEnd: DEFAULT_RULESET.screenTime.schoolHours.end,
    schoolDays: DEFAULT_RULESET.screenTime.schoolHours.days,
    blockedCategories: DEFAULT_RULESET.webFilter.blockedCategories,
    allowedDomains: DEFAULT_RULESET.webFilter.allowedDomains,
    blockedDomains: DEFAULT_RULESET.webFilter.blockedDomains,
    safeSearchEnforced: DEFAULT_RULESET.webFilter.safeSearchEnforced,
    youtubeRestrictedMode: DEFAULT_RULESET.webFilter.youtubeRestrictedMode,
    appRules: DEFAULT_RULESET.appRules,
    routines: DEFAULT_RULESET.routines,
    appGroupRules: DEFAULT_RULESET.appGroupRules,
    alwaysAllowedApps: DEFAULT_RULESET.alwaysAllowedApps,
    bonusMinutesToday: DEFAULT_RULESET.bonusMinutesToday,
    socialMonitoring: DEFAULT_RULESET.socialMonitoring,
    contactAllowlist: DEFAULT_RULESET.contactAllowlist,
  };
}
