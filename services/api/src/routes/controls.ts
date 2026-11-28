import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { getJson, publishJson } from "../redis.js";
import { requireParent, requireFamily, requirePermission } from "../middleware/requireFamily.js";
import { requireConsent } from "../middleware/requireConsent.js";
import { enqueueDeviceCommand } from "../lib/deviceCommands.js";
import { latestChildInternet, requestChildInternet } from "../lib/childInternet.js";
import { defaultRuleSetRow } from "../lib/defaultRules.js";
import { filterAgentRules, toApiRuleSet } from "../lib/ruleSync.js";
import { actingAdultName, withByName } from "../lib/actingAdult.js";

const BonusSchema = z.object({
  minutes: z.number().int().min(1),
});

const WindDownSchema = z.object({
  minutes: z.number().int().min(1),
});

/** Requested state from revisions that did not record device acknowledgements. */
function pausedKey(childId: string): string {
  return `child:${childId}:internet-paused`;
}

/** Enqueue the same command on every device belonging to the child. */
async function fanOutToDevices(childId: string, type: string, payload: Record<string, unknown> = {}, requestedBy?: string): Promise<void> {
  const devices = await prisma.device.findMany({ where: { childId }, select: { id: true } });
  for (const { id } of devices) {
    await enqueueDeviceCommand(id, type, payload, { requestedBy });
  }
}

export async function controlsRoutes(app: FastifyInstance) {
  const changeInternet = (paused: boolean) => async (req: FastifyRequest, reply: FastifyReply) => {
    const { childId } = req.params as { childId: string };
    if (!(await requestChildInternet(childId, paused, await actingAdultName(req)))) {
      return reply.code(404).send({ error: "child_not_found" });
    }
    return { childId, paused };
  };

  /** Sinkhole all of the child's internet traffic except always-allowed apps (Feature #11). */
  const pauseInternet = changeInternet(true);
  app.post(
    "/children/:childId/pause-internet",
    { preHandler: [requireParent, requirePermission("rules"), requireFamily({ param: "childId", model: "child" }), requireConsent({ param: "childId" })] },
    pauseInternet,
  );
  // Alias matching the parent app's shorter paths (Flutter controls_provider uses /pause).
  app.post(
    "/children/:childId/pause",
    { preHandler: [requireParent, requirePermission("rules"), requireFamily({ param: "childId", model: "child" }), requireConsent({ param: "childId" })] },
    pauseInternet,
  );

  /** Lift the internet pause on all of the child's devices (Feature #11). */
  const resumeInternet = changeInternet(false);
  app.post(
    "/children/:childId/resume-internet",
    { preHandler: [requireParent, requirePermission("rules"), requireFamily({ param: "childId", model: "child" })] },
    resumeInternet,
  );
  app.post(
    "/children/:childId/resume",
    { preHandler: [requireParent, requirePermission("rules"), requireFamily({ param: "childId", model: "child" })] },
    resumeInternet,
  );

  /** Grant extra screen time today only (Feature #10): increments bonusMinutesToday and notifies agents. */
  app.post(
    "/children/:childId/bonus",
    { preHandler: [requireParent, requirePermission("rules"), requireFamily({ param: "childId", model: "child" }), requireConsent({ param: "childId" })] },
    async (req, reply) => {
      const parsed = BonusSchema.safeParse(req.body);
      if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
      const { childId } = req.params as { childId: string };
      const { minutes } = parsed.data;
      // Upsert so a bonus can be granted before any ruleset exists; increment keeps
      // consecutive grants additive for the same day (column resets daily per migration).
      // Issue #475 review: the bonus is a rule write. The agent reads the extra minutes from the rules
      // payload, so a parent granting time while the phone is offline must see "hasn't picked this up
      // yet" — which needs the bump, in the same statement as the increment.
      const row = await prisma.ruleSet.upsert({
        where: { childId },
        create: { ...defaultRuleSetRow(childId), bonusMinutesToday: minutes },
        update: { bonusMinutesToday: { increment: minutes }, rulesVersion: { increment: 1 } },
      });
      const api = toApiRuleSet(row as unknown as Record<string, unknown>);
      await fanOutToDevices(childId, "bonus_time", withByName({ minutes }, await actingAdultName(req)), (req.user as { sub?: string }).sub);
      // Agents read the extra minutes from the rules payload, so republish it on every grant.
      await publishJson(`child:${childId}:rules`, await filterAgentRules(childId, api));
      return api;
    },
  );

  /** Start a bedtime-style wind-down on all of the child's devices (Feature #22). */
  app.post(
    "/children/:childId/wind-down",
    { preHandler: [requireParent, requirePermission("rules"), requireFamily({ param: "childId", model: "child" }), requireConsent({ param: "childId" })] },
    async (req, reply) => {
      const parsed = WindDownSchema.safeParse(req.body);
      if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
      const { childId } = req.params as { childId: string };
      const { minutes } = parsed.data;
      await fanOutToDevices(childId, "wind_down", withByName({ minutes }, await actingAdultName(req)), (req.user as { sub?: string }).sub);
      return { childId, minutes };
    },
  );

  /** Return the last requested internet setting and any exact device receipts. */
  app.get(
    "/children/:childId/status",
    { preHandler: [requireParent, requirePermission("rules"), requireFamily({ param: "childId", model: "child" })] },
    async (req) => {
      const { childId } = req.params as { childId: string };
      const operation = await latestChildInternet(childId);
      if (operation) return operation;
      const paused = await getJson<{ pausedAt: string }>(pausedKey(childId));
      return { paused: paused !== null };
    },
  );
}
