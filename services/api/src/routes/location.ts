import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { raiseAlert } from "../lib/alerts.js";
import { geofenceTransition, pickTransitionPair, type GeofencePoint } from "../lib/geo.js";
import { publishChildRules } from "../lib/ruleSync.js";
import { publishFamilyEvent } from "../realtime/gateway.js";
import { getRedis } from "../redis.js";
import { registerRawBodyParser, authenticateInternalRequest } from "../lib/internalAuth.js";
import { requireFamily, requireParent, requirePermission } from "../middleware/requireFamily.js";
import { requireConsent } from "../middleware/requireConsent.js";
import { assertProcessingAllowed } from "../lib/consent.js";

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
 * preHandler for POST /ping: accepts only a device JWT (`role: "device"` with its device/child claims,
 * revocation-checked) or a valid HMAC request. A verified signature alone proves who signed the token,
 * not that the bearer may write location data: a password-reset token or a token with no role must be
 * 401, not fall through to the ping handler (where a missing familyId used to skip the family check).
 *
 * Plan 2.7 F4 (Claude, #329, 2026-10-23): a parent JWT is refused with `403 device_role_required`,
 * the refusal the other device-only routes send. A parent ping could move a child into a geofence
 * whose routine applies rules (bypassing the `rules` permission) and falsify the location history;
 * no client sends one (the parent app never calls this route, and e2e signs with HMAC).
 */
async function pingAuth(req: FastifyRequest, reply: FastifyReply): Promise<void> {
  let jwtVerified = false;
  try {
    await req.jwtVerify();
    jwtVerified = true;
  } catch {
    /* fall through to HMAC */
  }
  if (jwtVerified) {
    const user = req.user as AuthedUser | undefined;
    if (user?.role === "parent") {
      await reply.code(403).send({ error: "device_role_required", hint: "location pings come from the child's device" });
      return;
    }
    if (user?.role === "device" && user.deviceId && user.childId && user.familyId) {
      // #351: the revoked-device answer comes from the global sessionGuard hook (server.ts), which runs
      // before this route. A local copy here was a second Redis GET per request that the hook had
      // already answered.
      return;
    }
    await reply.code(401).send({ error: "unauthorized" });
    return;
  }
  const rawBody = (req as { rawBody?: string }).rawBody;
  const auth = await authenticateInternalRequest(
    rawBody,
    req.headers["x-familyshield-signature"],
    req.headers as Record<string, string | string[] | undefined>,
  );
  if (auth.valid) {
    if (auth.device) {
      (req as unknown as { authDevice: unknown }).authDevice = auth.device;
    }
    return;
  }
  await reply.code(401).send({ error: "unauthorized", reason: auth.reason });
}

/** "14 h" for a whole number of hours, "7 h 13 min" otherwise — the old-position age in an alert. */
function formatStaleGap(minutes: number): string {
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  if (hours === 0) return `${rest} min`;
  return rest === 0 ? `${hours} h` : `${hours} h ${rest} min`;
}

/**
 * Evaluate geofence enter/exit transitions for this upload and raise alerts.
 *
 * `upload` is the batch as received, in whatever order the agent sent it: `pickTransitionPair` sorts
 * it and chooses the two pings to judge, so an unordered `mem + stored` upload is read from its
 * newest ping (issue #243 review, F2).
 */
async function evaluateGeofences(
  childId: string,
  familyId: string,
  upload: GeofencePoint[],
  deviceId: string,
  receivedAt: Date,
): Promise<void> {
  const fences = await prisma.geofence.findMany({ where: { childId } });
  if (fences.length === 0) return;
  // Review API-9: scope the previous ping to THIS device — with multiple devices a
  // cross-device latest ping would misfire enter/exit transitions.
  const previous = await prisma.locationPing.findFirst({
    where: { childId, deviceId },
    orderBy: { timestamp: "desc" },
  });
  // Issue #243: `null` means the upload is not newer than what is stored; `{ baseline: true }` means
  // there is no `before` at all (first ping ever, or retention deleted the history). Neither raises
  // an alert, and neither fires the school-routine nudge.
  const pair = pickTransitionPair(previous, upload, receivedAt);
  if (!pair || "baseline" in pair) return;
  for (const fence of fences) {
    const transition = geofenceTransition(pair.before, pair.now, fence);
    if (transition.kind !== "entered" && transition.kind !== "exited") continue;
    const entered = transition.kind === "entered";
    const notifyEnter = entered && fence.notifyOnEnter;
    const notifyExit = !entered && fence.notifyOnExit;
    if (!notifyEnter && !notifyExit) continue;
    const title = entered ? `Entered ${fence.label}` : `Left ${fence.label}`;
    const gapNote = transition.gapMinutes === null
      ? ""
      : ` No location for ${formatStaleGap(transition.gapMinutes)} before this.`;
    await raiseAlert({
      childId,
      familyId,
      deviceId,
      severity: "info",
      category: "geofence",
      title,
      body: `${title} (geofence "${fence.label}", ${fence.radiusM} m radius).${gapNote}`,
      // Privacy (Claude's #242 review): the alert names the fence, never the child's position. A
      // geofence crossing used to carry lat/lng in metadata, and Alert rows are not touched by the
      // retention job — so exact coordinates would have outlived the 30-day location window this PR
      // introduces, contradicting the consent copy. The fence's own position is in `Geofence`.
      // Issue #243 adds only the age of the previous position, in minutes — still no coordinates.
      metadata: {
        geofenceId: fence.id,
        label: fence.label,
        ...(transition.gapMinutes === null ? {} : { gapMinutes: transition.gapMinutes }),
      },
    });
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

    // Verify family matching. pingAuth only lets a JWT reach here with a familyId, so for a JWT
    // caller this check is unconditional — an HMAC request has no `user` and is covered by the
    // device-identity checks below.
    if (user && child.familyId !== user.familyId) {
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

    // ADR-0008 §2b: withdrawal of consent stops collection.
    if (!(await assertProcessingAllowed(effectiveChildId, reply))) return;

    // Issue #243 review (F2): the upload is not in time order — the agent sends fresh in-memory
    // pings first, then older Room-buffered ones. `pickTransitionPair` sorts it by `timestamp` and
    // merges the stored previous ping; a ping with no `timestamp` is stored with the schema's
    // `now()` default, so it counts as received at `receivedAt`.
    const receivedAt = new Date();
    await evaluateGeofences(
      effectiveChildId,
      child.familyId,
      pingsList.map((p) => ({ lat: p.lat, lng: p.lng, timestamp: p.timestamp ?? null })),
      effectiveDeviceId,
      receivedAt,
    );

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

    // Issue #253: an open map has no way to learn that a ping arrived — the parent app's `location`
    // branch was dead code. Publish one event per upload (not per ping: the app refetches the newest
    // position once) with the child id and the ping's timestamp only. Coordinates never travel on the
    // bus; the client reads them through the authorised `GET /:childId/latest` (#242). Best-effort:
    // the rows are already stored, so a Redis failure must not fail the upload.
    //
    // The payload timestamp is the FRESHEST ping in the upload, not the last one in the array: since
    // #243 we know the agent sends fresh in-memory pings first and the older buffered ones after, so
    // `last.timestamp` would advertise a stale time for a fresh position.
    const freshest = createdPings.reduce(
      (newest, ping) => (ping.timestamp > newest.timestamp ? ping : newest),
      createdPings[0],
    );
    await publishFamilyEvent(child.familyId, {
      type: "location",
      payload: { childId: effectiveChildId, ts: freshest.timestamp },
      ts: new Date().toISOString(),
    }).catch(() => undefined);

    return reply.code(201).send({ ping: last, pings: createdPings, count: createdPings.length });
  });

  /** Return the child's most recent location ping. */
  app.get("/:childId/latest", { preHandler: requireFamily({ param: "childId", model: "child", deviceAccess: "own-child" }) }, async (req, reply) => {
    const { childId } = req.params as { childId: string };
    const latest = await prisma.locationPing.findFirst({
      where: { childId },
      orderBy: { timestamp: "desc" },
    });
    if (!latest) return reply.code(404).send({ error: "no_pings" });
    return { latest };
  });

  /** Return the child's ping history within an optional from/to window. */
  app.get("/:childId/history", { preHandler: requireFamily({ param: "childId", model: "child", deviceAccess: "own-child" }) }, async (req, reply) => {
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
  app.get("/geofences/:childId", { preHandler: requireFamily({ param: "childId", model: "child", deviceAccess: "own-child" }) }, async (req) => {
    const { childId } = req.params as { childId: string };
    const geofences = await prisma.geofence.findMany({ where: { childId } });
    return { geofences };
  });

  /** Create a geofence for a child of the authenticated family. */
  app.post("/geofences", { preHandler: [requireParent, requirePermission("location"), requireFamily({ param: "childId", model: "child", source: "body" }), requireConsent({ param: "childId", source: "body" })] }, async (req, reply) => {
    const parsed = GeofenceCreateSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const { childId, ...data } = parsed.data;
    const geofence = await prisma.geofence.create({ data: { childId, ...data } });
    return reply.code(201).send({ geofence });
  });

  /** Delete a geofence. */
  app.delete("/geofences/:id", { preHandler: [requireParent, requirePermission("location"), requireFamily({ model: "geofence" })] }, async (req) => {
    const { id } = req.params as { id: string };
    await prisma.geofence.delete({ where: { id } });
    return { deleted: true, id };
  });
}
