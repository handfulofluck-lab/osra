import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { requireFamily, requireParent } from "../middleware/requireFamily.js";
import { computeWellbeingScore, currentIsoWeek, summarizeChildActivity } from "../lib/activitySummary.js";

const ActivityReportQuerySchema = z.object({
  childId: z.string().min(1),
  from: z.string().datetime().optional(),
  to: z.string().datetime().optional(),
  type: z.enum(["url", "app_usage", "call", "sms"]).optional(),
  limit: z.coerce.number().int().min(1).max(1000).default(200),
});

const SummaryQuerySchema = z.object({
  childId: z.string().min(1),
  days: z.coerce.number().int().min(1).max(90).default(7),
});

const WellbeingQuerySchema = z.object({
  week: z.string().regex(/^\d{4}-W\d{2}$/).optional(),
});

export async function reportsRoutes(app: FastifyInstance) {
  /** Persisted device activity for a child, newest first, family-scoped (#4). */
  app.get("/activity", { preHandler: [requireParent, requireFamily({ param: "childId", model: "child", source: "query" })] }, async (req, reply) => {
    const parsed = ActivityReportQuerySchema.safeParse(req.query ?? {});
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const q = parsed.data;
    const rows = await prisma.activityEvent.findMany({
      where: {
        childId: q.childId,
        ...(q.type ? { type: q.type } : {}),
        ...(q.from || q.to
          ? { ts: { ...(q.from ? { gte: new Date(q.from) } : {}), ...(q.to ? { lte: new Date(q.to) } : {}) } }
          : {}),
      },
      orderBy: { ts: "desc" },
      take: q.limit,
    });
    return { items: rows };
  });

  /** Aggregated window summary: app minutes, top apps, urls, blocked domains, calls/SMS (#4). */
  app.get("/summary", { preHandler: [requireParent, requireFamily({ param: "childId", model: "child", source: "query" })] }, async (req, reply) => {
    const parsed = SummaryQuerySchema.safeParse(req.query ?? {});
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const summary = await summarizeChildActivity(parsed.data.childId, parsed.data.days);
    return { childId: parsed.data.childId, days: parsed.data.days, ...summary };
  });

  /** Computed 0-100 wellbeing score for the trailing week, with penalty breakdown (#28). */
  app.get("/wellbeing/:childId", { preHandler: [requireParent, requireFamily({ param: "childId", model: "child" })] }, async (req, reply) => {
    const parsed = WellbeingQuerySchema.safeParse(req.query ?? {});
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const { childId } = req.params as { childId: string };
    const week = parsed.data.week ?? currentIsoWeek();
    return computeWellbeingScore(childId, week);
  });
}
