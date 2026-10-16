import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { getRedis, getJson, publishJson, setJson } from "../redis.js";
import { requireParent, requireFamily } from "../middleware/requireFamily.js";
import { requireConsent } from "../middleware/requireConsent.js";
import { enqueueDeviceCommand } from "../lib/deviceCommands.js";
import { defaultRuleSetRow } from "../lib/defaultRules.js";
import { toApiRuleSet } from "./rules.js";

const BonusSchema = z.object({
  minutes: z.number().int().min(1),
});

const WindDownSchema = z.object({
  minutes: z.number().int().min(1),
});

/** Redis key holding the child's internet-paused state (set by pause, cleared by resume). */
function pausedKey(childId: string): string {
  return `child:${childId}:internet-paused`;
}

/** Enqueue the same command on every device belonging to the child. */
async function fanOutToDevices(childId: string, type: string, payload: Record<string, unknown> = {}): Promise<void> {
  const devices = await prisma.device.findMany({ where: { childId }, select: { id: true } });
  for (const { id } of devices) {
    await enqueueDeviceCommand(id, type, payload);
  }
}

export async function controlsRoutes(app: FastifyInstance) {
  /** Sinkhole all of the child's internet traffic except always-allowed apps (Feature #11). */
  const pauseInternet = async (req: unknown) => {
    const { childId } = (req as { params: { childId: string } }).params;
    await fanOutToDevices(childId, "pause_internet");
    // Server-side paused flag so the parent app can show a live chip; agents confirm via status.
    await setJson(pausedKey(childId), { pausedAt: new Date().toISOString() });
    return { childId, paused: true };
  };
  app.post(
    "/children/:childId/pause-internet",
    { preHandler: [requireParent, requireFamily({ param: "childId", model: "child" }), requireConsent({ param: "childId" })] },
    pauseInternet,
  );
  // Alias matching the parent app's shorter paths (Flutter controls_provider uses /pause).
  app.post(
    "/children/:childId/pause",
    { preHandler: [requireParent, requireFamily({ param: "childId", model: "child" }), requireConsent({ param: "childId" })] },
    pauseInternet,
  );

  /** Lift the internet pause on all of the child's devices (Feature #11). */
  const resumeInternet = async (req: unknown) => {
    const { childId } = (req as { params: { childId: string } }).params;
    await fanOutToDevices(childId, "resume_internet");
    await getRedis().del(pausedKey(childId));
    return { childId, paused: false };
  };
  app.post(
    "/children/:childId/resume-internet",
    { preHandler: [requireParent, requireFamily({ param: "childId", model: "child" }), requireConsent({ param: "childId" })] },
    resumeInternet,
  );
  app.post(
    "/children/:childId/resume",
    { preHandler: [requireParent, requireFamily({ param: "childId", model: "child" }), requireConsent({ param: "childId" })] },
    resumeInternet,
  );

  /** Grant extra screen time today only (Feature #10): increments bonusMinutesToday and notifies agents. */
  app.post(
    "/children/:childId/bonus",
    { preHandler: [requireParent, requireFamily({ param: "childId", model: "child" }), requireConsent({ param: "childId" })] },
    async (req, reply) => {
      const parsed = BonusSchema.safeParse(req.body);
      if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
      const { childId } = req.params as { childId: string };
      const { minutes } = parsed.data;
      // Upsert so a bonus can be granted before any ruleset exists; increment keeps
      // consecutive grants additive for the same day (column resets daily per migration).
      const row = await prisma.ruleSet.upsert({
        where: { childId },
        create: { ...defaultRuleSetRow(childId), bonusMinutesToday: minutes },
        update: { bonusMinutesToday: { increment: minutes } },
      });
      const api = toApiRuleSet(row as unknown as Record<string, unknown>);
      await fanOutToDevices(childId, "bonus_time", { minutes });
      // Agents read the extra minutes from the rules payload, so republish it on every grant.
      await publishJson(`child:${childId}:rules`, api);
      return api;
    },
  );

  /** Start a bedtime-style wind-down on all of the child's devices (Feature #22). */
  app.post(
    "/children/:childId/wind-down",
    { preHandler: [requireParent, requireFamily({ param: "childId", model: "child" }), requireConsent({ param: "childId" })] },
    async (req, reply) => {
      const parsed = WindDownSchema.safeParse(req.body);
      if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
      const { childId } = req.params as { childId: string };
      const { minutes } = parsed.data;
      await fanOutToDevices(childId, "wind_down", { minutes });
      return { childId, minutes };
    },
  );

  /** Return whether the child's internet is currently paused (Feature #11). */
  app.get(
    "/children/:childId/status",
    { preHandler: [requireParent, requireFamily({ param: "childId", model: "child" })] },
    async (req) => {
      const { childId } = req.params as { childId: string };
      const paused = await getJson<{ pausedAt: string }>(pausedKey(childId));
      return { paused: paused !== null };
    },
  );
}
