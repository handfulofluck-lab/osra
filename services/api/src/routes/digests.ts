import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { requireParent } from "../middleware/requireFamily.js";
import { summarizeChildActivity, type ActivitySummary } from "../lib/activitySummary.js";
import { sendFamilyDigest } from "../jobs/digestScheduler.js";
import { emailConfigured } from "../lib/email/index.js";

const PrefsSchema = z.object({
  dailyEmail: z.boolean(),
  weeklyEmail: z.boolean(),
  pushEnabled: z.boolean(),
  emails: z.array(z.string().email()).min(1),
});

type AuthedUser = { sub: string; familyId: string };

/** Default prefs when no DigestPrefs row exists: everything on, delivered to the parent's email. */
async function prefsOrDefault(familyId: string, parentId: string) {
  const row = await prisma.digestPrefs.findUnique({ where: { familyId } });
  if (row) return row;
  const parent = await prisma.parent.findUnique({ where: { id: parentId } });
  return {
    familyId,
    dailyEmail: true,
    weeklyEmail: true,
    pushEnabled: true,
    emails: parent ? [parent.email] : [],
  };
}

/** Render one child's summary as a markdown-ish digest body (#5). */
function renderDigest(displayName: string, days: number, summary: ActivitySummary): string {
  const lines = [
    `## OSRA digest — ${displayName}`,
    `Screen time (last ${days} days): ${summary.totalAppMinutes} min`,
    `Top apps: ${summary.topApps.map((a) => `${a.name} ${a.minutes}m`).join(", ") || "none"}`,
    `URL visits: ${summary.urlVisits}`,
    `Blocked domains: ${summary.topBlockedDomains.map((d) => `${d.domain} (${d.count})`).join(", ") || "none"}`,
    `Social concerns: ${summary.socialConcerns}`,
    `Calls: ${summary.calls}, SMS: ${summary.sms}`,
  ];
  return lines.join("\n");
}

export async function digestRoutes(app: FastifyInstance) {
  /** Read the family's digest preferences (default: all-true, emails=[parent email]) (#5). */
  app.get("/prefs", { preHandler: requireParent }, async (req) => {
    const user = req.user as AuthedUser;
    return prefsOrDefault(user.familyId, user.sub);
  });

  /** Upsert the family's digest preferences (#5). */
  app.put("/prefs", { preHandler: requireParent }, async (req, reply) => {
    const parsed = PrefsSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const user = req.user as AuthedUser;
    const prefs = await prisma.digestPrefs.upsert({
      where: { familyId: user.familyId },
      update: parsed.data,
      create: { familyId: user.familyId, ...parsed.data },
    });
    return prefs;
  });

  /**
   * Render the digest for every child and, when an email provider is configured, deliver it to
   * the family's digest recipients right now (Phase 2a). Scheduled delivery is
   * `jobs/digestScheduler.ts`; this route is the parent-triggered "send me one now".
   */
  app.post("/send-now", { preHandler: requireParent }, async (req) => {
    const user = req.user as AuthedUser;
    const body = (req.body ?? {}) as { kind?: "daily" | "weekly" };
    const kind = body.kind === "daily" ? "daily" : "weekly";
    const days = kind === "daily" ? 1 : 7;
    const children = await prisma.child.findMany({ where: { familyId: user.familyId } });
    const digests = [];
    for (const child of children) {
      const summary = await summarizeChildActivity(child.id, days);
      digests.push({
        childId: child.id,
        displayName: child.displayName,
        markdown: renderDigest(child.displayName, days, summary),
      });
    }
    const delivery = await sendFamilyDigest(user.familyId, kind);
    return { digests, emailed: delivery.sent && emailConfigured(), recipients: delivery.to, reason: delivery.reason };
  });
}
