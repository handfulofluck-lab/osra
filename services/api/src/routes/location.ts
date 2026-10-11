import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { publishFamilyEvent } from "../realtime/gateway.js";
import { isInsideFence } from "../lib/geo.js";
import { publishChildRules } from "../lib/ruleSync.js";
import { getRedis } from "../redis.js";
import { registerRawBodyParser, authenticateInternalRequest } from "../lib/internalAuth.js";
import { requireFamily, requireParent } from "../middleware/requireFamily.js";

const PingSchema = z.object({
  childId: z.string().min(1),
  deviceId: z.string().min(1),
  lat: z.number().min(-90).max(90),
  lng: z.number().min(-180).max(180),
  accuracyM: z.number().min(0).default(0),
  timestamp: z.string().datetime().optional(),
});

const GeofenceCreateSchema = z.object({
  childId: z.string().min(1),
  label: z.string().min(1),
  lat: z.number().min(-90).max(90),
  lng: z.number().min(-180).max(180),
  radiusM: z.number().int().min(10).max(100000),
  notifyOnEnter: z.boolean().default(true),
  notifyOnExit: z.boolean().default(true),
  // Feature #23: routine bound to this fence; entering it auto-applies the routine rules.
  routineId: z.string().min(1).optional(),
});

const HistoryQuerySchema = z.object({
  from: z.string().datetime().optional(),
  to: z.string().datetime().optional(),
});

type AuthedUser = { familyId: string; sub?: string; role?: string; deviceId?: string; childId?: string };

/**
 * preHandler for POST /ping: accepts a parent JWT, or falls back to the
 * X-FamilyShield-Signature HMAC scheme used by device/agent internal calls.
 */
async function pingAuth(req: FastifyRequest, reply: FastifyReply): Promise<void> {
  try {
    await req.jwtVerify();
    const user = req.user as AuthedUser | undefined;
    if (user?.role === "device" && user.deviceId) {
      const redis = getRedis();
      const revoked = await redis.get(`revoked:device:${user.deviceId}`).catch(() => null);
      if (revoked) {
        await reply.code(401).send({ error: "device_revoked" });
        return;
      }
    }
    return;
  } catch {
    /* fall through to HMAC */
  }
  const rawBody = (req as { rawBody?: string }).rawBody;
  const auth = await authenticateInternalRequest(
    rawBody,
    req.headers["x-familyshield-signature"],
    req.headers as Record<string, string | string[] | undefined>,
  );
  if (auth.valid) {
    if (auth.device) {
      if (auth.device.revokedAt) {
        await reply.code(401).send({ error: "device_revoked" });
        return;
      }
      (req as unknown as { authDevice: unknown }).authDevice = auth.device;
    }
    return;
  }
  await reply.code(401).send({ error: "unauthorized" });
}

/** Evaluate geofence enter/exit transitions for a fresh ping and raise alerts. */
async function evaluateGeofences(
  childId: string,
  familyId: string,
  lat: number,
  lng: number,
  deviceId: string,
): Promise<void> {
  const fences = await prisma.geofence.findMany({ where: { childId } });
  if (fences.length === 0) return;
  // Review API-9: scope the previous ping to THIS device — with multiple devices a
  // cross-device latest ping would misfire enter/exit transitions.
  const previous = await prisma.locationPing.findFirst({
    where: { childId, deviceId },
    orderBy: { timestamp: "desc" },
  });
  for (const fence of fences) {
    const insideNow = isInsideFence(lat, lng, fence);
    const insideBefore = previous ? isInsideFence(previous.lat, previous.lng, fence) : false;
    if (insideNow === insideBefore) continue;
    const entered = insideNow && fence.notifyOnEnter;
    const exited = !insideNow && fence.notifyOnExit;
    if (!entered && !exited) continue;
    const title = entered ? `Entered ${fence.label}` : `Left ${fence.label}`;
    const alert = await prisma.alert.create({
      data: {
        childId,
        deviceId,
        severity: "info",
        category: "geofence",
        title,
        body: `${title} (geofence "${fence.label}", ${fence.radiusM} m radius)`,
        metadata: { geofenceId: fence.id, label: fence.label, lat, lng },
      },
    });
    await publishFamilyEvent(familyId, { type: "alert", payload: alert, ts: new Date().toISOString() });
    // Feature #23: entering a school/routine fence auto-applies the bound routine — push the
    // child's ruleset and nudge every device to refresh.
    if (entered && fence.routineId) {
      await publishChildRules(childId, "geofence_routine");
    }
  }
}

export async function locationRoutes(app: FastifyInstance) {
  registerRawBodyParser(app);

  /** Ingest a location ping (parent JWT or HMAC device auth) and evaluate geofences. */
  app.post("/ping", { preHandler: pingAuth }, async (req, reply) => {
    const parsed = PingSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const { childId, deviceId, lat, lng, accuracyM, timestamp } = parsed.data;

    const child = await prisma.child.findUnique({ where: { id: childId } });
    if (!child) return reply.code(404).send({ error: "child_not_found" });
    const user = req.user as AuthedUser | undefined;
    if (user?.familyId && child.familyId !== user.familyId) {
      return reply.code(403).send({ error: "forbidden" });
    }
    const authDevice = (req as unknown as { authDevice?: { id: string; childId: string } }).authDevice;
    if (user?.role === "device") {
      if (user.deviceId && user.deviceId !== deviceId) {
        return reply.code(403).send({ error: "device_mismatch" });
      }
      if (user.childId && user.childId !== childId) {
        return reply.code(403).send({ error: "cross_child_forbidden" });
      }
    } else if (authDevice) {
      if (authDevice.id !== deviceId) {
        return reply.code(403).send({ error: "device_mismatch" });
      }
      if (authDevice.childId && authDevice.childId !== childId) {
        return reply.code(403).send({ error: "cross_child_forbidden" });
      }
    }

    // Evaluate transitions against the previous latest ping before inserting this one.
    await evaluateGeofences(childId, child.familyId, lat, lng, deviceId);

    let ping;
    try {
      ping = await prisma.locationPing.create({
        data: { childId, deviceId, lat, lng, accuracyM, timestamp: timestamp ? new Date(timestamp) : undefined },
      });
    } catch {
      return reply.code(401).send({ error: "device_revoked" });
    }
    // A device that pings is alive — keep lastSeen fresh for the parent app.
    try {
      await prisma.device.update({ where: { id: deviceId }, data: { lastSeen: new Date(), status: "online" } });
    } catch {
      // lastSeen refresh is best-effort and must never fail the ping
    }
    return reply.code(201).send({ ping });
  });

  /** Return the child's most recent location ping. */
  app.get("/:childId/latest", { preHandler: requireFamily({ param: "childId", model: "child" }) }, async (req, reply) => {
    const { childId } = req.params as { childId: string };
    const latest = await prisma.locationPing.findFirst({
      where: { childId },
      orderBy: { timestamp: "desc" },
    });
    if (!latest) return reply.code(404).send({ error: "no_pings" });
    return { latest };
  });

  /** Return the child's ping history within an optional from/to window. */
  app.get("/:childId/history", { preHandler: requireFamily({ param: "childId", model: "child" }) }, async (req, reply) => {
    const { childId } = req.params as { childId: string };
    const parsed = HistoryQuerySchema.safeParse(req.query ?? {});
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const query = parsed.data;
    const pings = await prisma.locationPing.findMany({
      where: {
        childId,
        ...(query.from || query.to
          ? { timestamp: { ...(query.from ? { gte: new Date(query.from) } : {}), ...(query.to ? { lte: new Date(query.to) } : {}) } }
          : {}),
      },
      orderBy: { timestamp: "desc" },
      take: 500,
    });
    return { pings };
  });

  /** List geofences for a child. */
  app.get("/geofences/:childId", { preHandler: requireFamily({ param: "childId", model: "child" }) }, async (req) => {
    const { childId } = req.params as { childId: string };
    const geofences = await prisma.geofence.findMany({ where: { childId } });
    return { geofences };
  });

  /** Create a geofence for a child of the authenticated family. */
  app.post("/geofences", { preHandler: [requireParent, requireFamily({ param: "childId", model: "child", source: "body" })] }, async (req, reply) => {
    const parsed = GeofenceCreateSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const { childId, ...data } = parsed.data;
    const geofence = await prisma.geofence.create({ data: { childId, ...data } });
    return reply.code(201).send({ geofence });
  });

  /** Delete a geofence. */
  app.delete("/geofences/:id", { preHandler: [requireParent, requireFamily({ model: "geofence" })] }, async (req) => {
    const { id } = req.params as { id: string };
    await prisma.geofence.delete({ where: { id } });
    return { deleted: true, id };
  });
}
