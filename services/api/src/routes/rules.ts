import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { publishJson } from "../redis.js";
import { requireParent, requireFamily, requirePermission } from "../middleware/requireFamily.js";
import { requireConsent } from "../middleware/requireConsent.js";
import { assertProcessingAllowed } from "../lib/consent.js";
import { enqueueDeviceCommand } from "../lib/deviceCommands.js";
import { DEFAULT_RULESET } from "../lib/defaultRules.js";
import { toApiRuleSet } from "../lib/ruleSync.js";

// Kept as a re-export so existing importers (controls.ts) keep working while the
// shared mapper lives in lib with the publish fan-out (no routes↔routes imports).
export { toApiRuleSet };

const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/;

const ScreenTimeSchema = z.object({
  dailyLimitMinutes: z.number().int().min(0).max(10080),
  weekendLimitMinutes: z.number().int().min(0).max(10080),
  bedtimeStart: z.string().regex(HHMM),
  bedtimeEnd: z.string().regex(HHMM),
  schoolHours: z.object({
    start: z.string().regex(HHMM),
    end: z.string().regex(HHMM),
    // Canonical day encoding is 1=Mon..7=Sun across parent app, agents and API (BUG-002):
    // 0 is rejected so a stored 0 can never produce an out-of-range UI index downstream.
    days: z.array(z.number().int().min(1).max(7)),
  }),
});

const WebFilterSchema = z.object({
  blockedCategories: z.array(z.string().max(255)).max(100),
  allowedDomains: z.array(z.string().max(255)).max(1000),
  blockedDomains: z.array(z.string().max(255)).max(1000),
  safeSearchEnforced: z.boolean(),
  youtubeRestrictedMode: z.enum(["strict", "moderate", "off"]).optional(),
});

const AppRuleSchema = z.object({
  packageId: z.string().min(1),
  appName: z.string().min(1),
  action: z.enum(["allow", "block", "time_limit"]),
  dailyLimitMinutes: z.number().int().min(0).max(10080).optional(),
});

const RoutineSchema = z.object({
  id: z.string().min(1).optional(),
  name: z.string().min(1),
  startTime: z.string().regex(HHMM),
  endTime: z.string().regex(HHMM),
  days: z.array(z.number().int().min(1).max(7)),
  blockedApps: z.array(z.string()),
  allowedApps: z.array(z.string()),
});

const RuleSetInputSchema = z.object({
  screenTime: ScreenTimeSchema,
  webFilter: WebFilterSchema,
  appRules: z.array(AppRuleSchema),
  routines: z.array(RoutineSchema),
  alwaysAllowedApps: z.array(z.string()).default([]),
  allowOverlap: z.boolean().optional(),
  // NOTE: socialMonitoring maps app names (whatsapp, tiktok, ...) to capture-enabled flags;
  // contactAllowlist holds normalized phone numbers that bypass social scanning (#27).
  socialMonitoring: z.record(z.boolean()).default({}),
  contactAllowlist: z.array(z.string()).default([]),
});

const RuleSetPatchSchema = z.object({
  screenTime: ScreenTimeSchema.partial().optional(),
  webFilter: WebFilterSchema.partial().optional(),
  appRules: z.array(AppRuleSchema).optional(),
  routines: z.array(RoutineSchema).optional(),
  alwaysAllowedApps: z.array(z.string()).optional(),
  allowOverlap: z.boolean().optional(),
  socialMonitoring: z.record(z.boolean()).optional(),
  contactAllowlist: z.array(z.string()).optional(),
});

/** Convert "HH:MM" to minutes since midnight. */
export function toMinutes(hhmm: string): number {
  const [h, m] = hhmm.split(":").map(Number);
  return h * 60 + m;
}

/** True when two daily windows (supporting overnight wrap) share any minute. */
export function windowsOverlap(start1: string, end1: string, start2: string, end2: string): boolean {
  const day = 1440;
  const s1 = toMinutes(start1);
  const e1 = toMinutes(end1);
  const s2 = toMinutes(start2);
  const e2 = toMinutes(end2);
  const covers = (s: number, e: number, t: number) =>
    s === e ? true : s < e ? t >= s && t < e : t >= s || t < e;
  // Sample the second window's boundary minutes against the first window.
  return covers(s1, e1, s2) || covers(s1, e1, (e2 - 1 + day) % day) ||
    covers(s2, e2, s1) || covers(s2, e2, (e1 - 1 + day) % day);
}

/** Push a rules_updated command to every device of the child so HTTP-polling agents refresh. */
async function notifyDevices(childId: string): Promise<void> {
  const devices = await prisma.device.findMany({ where: { childId }, select: { id: true } });
  for (const { id } of devices) {
    await enqueueDeviceCommand(id, "rules_updated", { reason: "rules_changed" });
  }
}

/** Map the nested API shape back to flat Prisma RuleSet columns. */
function toRow(data: z.infer<typeof RuleSetInputSchema>, childId: string) {
  return {
    childId,
    dailyLimitMinutes: data.screenTime.dailyLimitMinutes,
    weekendLimitMinutes: data.screenTime.weekendLimitMinutes,
    bedtimeStart: data.screenTime.bedtimeStart,
    bedtimeEnd: data.screenTime.bedtimeEnd,
    schoolHoursStart: data.screenTime.schoolHours.start,
    schoolHoursEnd: data.screenTime.schoolHours.end,
    schoolDays: data.screenTime.schoolHours.days,
    blockedCategories: data.webFilter.blockedCategories,
    allowedDomains: data.webFilter.allowedDomains,
    blockedDomains: data.webFilter.blockedDomains,
    safeSearchEnforced: data.webFilter.safeSearchEnforced,
    youtubeRestrictedMode: data.webFilter.youtubeRestrictedMode ?? "strict",
    appRules: data.appRules,
    routines: data.routines,
    alwaysAllowedApps: data.alwaysAllowedApps,
    socialMonitoring: data.socialMonitoring,
    contactAllowlist: data.contactAllowlist,
  };
}

/** Reject overlapping bedtime/school windows unless the payload opts out with allowOverlap. */
function overlapError(data: z.infer<typeof RuleSetInputSchema>): string | null {
  if (data.allowOverlap) return null;
  const { bedtimeStart, bedtimeEnd, schoolHours } = data.screenTime;
  if (windowsOverlap(bedtimeStart, bedtimeEnd, schoolHours.start, schoolHours.end)) {
    return `bedtime window ${bedtimeStart}-${bedtimeEnd} overlaps school hours ${schoolHours.start}-${schoolHours.end}; set allowOverlap: true to permit this`;
  }
  return null;
}

export async function rulesRoutes(app: FastifyInstance) {
  /** Return the child's ruleset (nested API shape), or defaults when none exists. */
  app.get("/:childId", { preHandler: requireFamily({ param: "childId", model: "child", deviceAccess: "own-child" }) }, async (req, reply) => {
    const { childId } = req.params as { childId: string };
    // ADR-0008 §2b: a device must not keep enforcing or collecting once consent is withdrawn;
    // parents may still read the (dormant) ruleset.
    const user = req.user as { role?: string } | undefined;
    if (user?.role === "device" && !(await assertProcessingAllowed(childId, reply))) return;
    const row = await prisma.ruleSet.findUnique({ where: { childId } });
    return row ? toApiRuleSet(row as unknown as Record<string, unknown>) : { childId, ...DEFAULT_RULESET };
  });

  /** Full validated upsert of a child's ruleset; publishes the ruleset to Redis. */
  app.put("/:childId", { preHandler: [requireParent, requirePermission("rules"), requireFamily({ param: "childId", model: "child" }), requireConsent({ param: "childId" })] }, async (req, reply) => {
    const parsed = RuleSetInputSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const overlap = overlapError(parsed.data);
    if (overlap) return reply.code(400).send({ error: overlap });
    const { childId } = req.params as { childId: string };
    const row = await prisma.ruleSet.upsert({
      where: { childId },
      create: toRow(parsed.data, childId),
      update: toRow(parsed.data, childId),
    });
    const api = toApiRuleSet(row as unknown as Record<string, unknown>);
    await publishJson(`child:${childId}:rules`, api);
    await notifyDevices(childId);
    return api;
  });

  /** Deep-merge a partial ruleset update onto the existing ruleset; publishes to Redis. */
  app.patch("/:childId", { preHandler: [requireParent, requirePermission("rules"), requireFamily({ param: "childId", model: "child" }), requireConsent({ param: "childId" })] }, async (req, reply) => {
    const { childId } = req.params as { childId: string };
    const parsed = RuleSetPatchSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const existing = await prisma.ruleSet.findUnique({ where: { childId } });
    const current = existing
      ? toApiRuleSet(existing as unknown as Record<string, unknown>)
      : ({ childId, ...DEFAULT_RULESET } as Record<string, unknown>);
    const patch = parsed.data as Record<string, unknown>;
    const merged = {
      screenTime: { ...(current.screenTime as object), ...(patch.screenTime as object) },
      webFilter: { ...(current.webFilter as object), ...(patch.webFilter as object) },
      appRules: patch.appRules ?? current.appRules,
      routines: patch.routines ?? current.routines,
      alwaysAllowedApps: patch.alwaysAllowedApps ?? current.alwaysAllowedApps ?? [],
      socialMonitoring: patch.socialMonitoring ?? current.socialMonitoring,
      contactAllowlist: patch.contactAllowlist ?? current.contactAllowlist,
    };
    const validated = RuleSetInputSchema.safeParse({ ...merged, allowOverlap: patch.allowOverlap });
    if (!validated.success) return reply.code(400).send({ error: validated.error.flatten() });
    // allowOverlap is an input-only flag (not persisted), so re-checking overlap on every
    // patch would reject unrelated updates to a ruleset created with allowOverlap: true.
    // Only validate when the patch actually changes a bedtime/school window.
    const sp = parsed.data.screenTime;
    const windowsTouched =
      sp?.bedtimeStart !== undefined || sp?.bedtimeEnd !== undefined || sp?.schoolHours !== undefined;
    if (windowsTouched) {
      const overlap = overlapError(validated.data);
      if (overlap) return reply.code(400).send({ error: overlap });
    }
    const row = await prisma.ruleSet.upsert({
      where: { childId },
      create: toRow(validated.data, childId),
      update: toRow(validated.data, childId),
    });
    const api = toApiRuleSet(row as unknown as Record<string, unknown>);
    await publishJson(`child:${childId}:rules`, api);
    await notifyDevices(childId);
    return api;
  });
}
