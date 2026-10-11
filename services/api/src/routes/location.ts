import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { publishFamilyEvent } from "../realtime/gateway.js";
import { isInsideFence } from "../lib/geo.js";
import { publishChildRules } from "../lib/ruleSync.js";
import { getRedis } from "../redis.js";
import { registerRawBodyParser, authenticateInternalRequest } from "../lib/internalAuth.js";
import { requireFamily, requireParent } from "../middleware/requireFamily.js";

const SinglePingItemSchema = z.object({
  childId: z.string().min(1).optional(),
  deviceId: z.string().min(1).optional(),
  lat: z.number().min(-90).max(90),
  lng: z.number().min(-180).max(180),
  accuracyM: z.number().min(0).default(0),
  timestamp: z.string().datetime().optional(),
});

const PingBatchEnvelopeSchema = z.object({
  childId: z.string().min(1).optional(),
  deviceId: z.string().min(1).optional(),
  pings: z.array(SinglePingItemSchema).min(1).max(500),
});

const PingPayloadSchema = z.union([
  PingBatchEnvelopeSchema,
  z.array(SinglePingItemSchema).min(1).max(500),
  SinglePingItemSchema,
]);

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

  /** Ingest a location ping or batch (parent JWT or HMAC device auth) and evaluate geofences. */
  app.post("/ping", { preHandler: pingAuth }, async (req, reply) => {
    const parsed = PingPayloadSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });

    let pingsList: z.infer<typeof SinglePingItemSchema>[] = [];
    let topChildId: string | undefined;
    let topDeviceId: string | undefined;

    if (Array.isArray(parsed.data)) {
      pingsList = parsed.data;
    } else if ("pings" in parsed.data && Array.isArray(parsed.data.pings)) {
      pingsList = parsed.data.pings;
      topChildId = parsed.data.childId;
      topDeviceId = parsed.data.deviceId;
    } else {
      const single = parsed.data as z.infer<typeof SinglePingItemSchema>;
      pingsList = [single];
      topChildId = single.childId;
      topDeviceId = single.deviceId;
    }

    if (pingsList.length === 0) {
      return reply.code(400).send({ error: "no_pings_in_payload" });
    }

    const user = req.user as AuthedUser | undefined;
    const authDevice = (req as unknown as { authDevice?: { id: string; childId: string } }).authDevice;

    // Resolve device and child identity from token/HMAC or top-level/ping items
    const effectiveDeviceId = (user?.role === "device" ? user.deviceId : undefined)
      ?? authDevice?.id
      ?? topDeviceId
      ?? pingsList[0]?.deviceId;

    const effectiveChildId = (user?.role === "device" ? user.childId : undefined)
      ?? authDevice?.childId
      ?? topChildId
      ?? pingsList[0]?.childId;

    if (!effectiveDeviceId || !effectiveChildId) {
      return reply.code(400).send({ error: "missing_device_or_child_identity" });
    }

    // Verify child exists
    const child = await prisma.child.findUnique({ where: { id: effectiveChildId } });
    if (!child) return reply.code(404).send({ error: "child_not_found" });

    // Verify family matching
    if (user?.familyId && child.familyId !== user.familyId) {
      return reply.code(403).send({ error: "forbidden" });
    }

    // Verify token identity claims vs body
    if (user?.role === "device") {
      if (user.deviceId && topDeviceId && user.deviceId !== topDeviceId) {
        return reply.code(403).send({ error: "device_mismatch" });
      }
      if (user.childId && topChildId && user.childId !== topChildId) {
        return reply.code(403).send({ error: "cross_child_forbidden" });
      }
    } else if (authDevice) {
      if (authDevice.id && topDeviceId && authDevice.id !== topDeviceId) {
        return reply.code(403).send({ error: "device_mismatch" });
      }
      if (authDevice.childId && topChildId && authDevice.childId !== topChildId) {
        return reply.code(403).send({ error: "cross_child_forbidden" });
      }
    }

    // Evaluate transitions against the latest ping in the batch
    const latestPing = pingsList[pingsList.length - 1];
    await evaluateGeofences(effectiveChildId, child.familyId, latestPing.lat, latestPing.lng, effectiveDeviceId);

    let createdPings;
    try {
      createdPings = await Promise.all(
        pingsList.map((p) =>
          prisma.locationPing.create({
            data: {
              childId: effectiveChildId,
              deviceId: effectiveDeviceId,
              lat: p.lat,
              lng: p.lng,
              accuracyM: p.accuracyM,
              timestamp: p.timestamp ? new Date(p.timestamp) : undefined,
            },
          }),
        ),
      );
    } catch {
      // Foreign key violation or missing device record -> 401 device_revoked
      return reply.code(401).send({ error: "device_revoked" });
    }

    // A device that pings is alive — keep lastSeen fresh for the parent app.
    try {
      await prisma.device.update({
        where: { id: effectiveDeviceId },
        data: { lastSeen: new Date(), status: "online" },
      });
    } catch {
      // best-effort
    }

    const last = createdPings[createdPings.length - 1];
    return reply.code(201).send({ ping: last, pings: createdPings, count: createdPings.length });
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
    return {
      pings: pings.map((p) => ({
        ...p,
        ts: p.timestamp,
      })),
    };
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
