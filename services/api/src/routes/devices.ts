import { randomBytes, randomInt } from "node:crypto";
import type { FastifyInstance } from "fastify";
import type { Prisma } from "@prisma/client";
import { z } from "zod";
import { prisma } from "../db.js";
import { getRedis, getJson, setJson, setJsonNx } from "../redis.js";
import { requireAuth, requireFamily, requireParent, sanitizeDevice } from "../middleware/requireFamily.js";
import { requireConsent } from "../middleware/requireConsent.js";
import { checkActiveConsent, assertProcessingAllowed } from "../lib/consent.js";
import { enqueueDeviceCommand } from "../lib/deviceCommands.js";
import { publishFamilyEvent } from "../realtime/gateway.js";

const PLATFORM = z.enum(["android", "ios", "windows", "macos", "chromebook"]);

const RegisterSchema = z.object({
  childId: z.string().min(1),
  platform: PLATFORM,
  model: z.string().min(1),
  osVersion: z.string().min(1),
  pushToken: z.string().optional(),
});

const CommandSchema = z.object({
  command: z.enum([
    "lock",
    "unlock",
    "ring",
    "sos_clear",
    "pause",
    "resume",
    // World-class addendum: internet kill-switch and time-grant commands (#11/#10/#22).
    "pause_internet",
    "resume_internet",
    "bonus_time",
    "wind_down",
  ]),
  payload: z.record(z.unknown()).optional(),
});

/** Commands that reduce restriction on the child and therefore never require active consent. */
const SAFE_DIRECTION_COMMANDS = new Set(["unlock", "resume", "resume_internet", "sos_clear"]);

const PushTokenSchema = z.object({ pushToken: z.string().min(1) });

const PairSchema = z.object({ childId: z.string().min(1) });

const ClaimSchema = z.object({
  code: z.string().regex(/^\d{6}$/),
  platform: PLATFORM,
  model: z.string().min(1),
  osVersion: z.string().min(1),
  deviceName: z.string().optional(),
  pushToken: z.string().optional(),
});

const PAIR_TTL_SECONDS = 600;
const PAIR_MAX_ATTEMPTS = 5;

const TelemetrySchema = z
  .object({
    batteryPct: z.number().int().min(0).max(100).optional(),
    totalMinutes: z.number().int().min(0).optional(),
    appUsage: z
      .array(z.object({ packageId: z.string().min(1), minutes: z.number().min(0) }))
      .optional(),
    urls: z.array(z.string()).optional(),
    timestamp: z.string().datetime().optional(),
  })
  .passthrough();

const ActivityBatchSchema = z.object({
  events: z
    .array(
      z.object({
        ts: z.string().datetime().optional(),
        type: z.enum(["url", "app_usage", "call", "sms"]),
        payload: z.record(z.unknown()),
      }),
    )
    .min(1)
    .max(500),
});

type AuthedUser = { sub: string; familyId: string; role?: string; deviceId?: string; childId?: string };

/** Generate a 6-digit pairing code and store its payload with a 600 s TTL, retrying on SET NX collision. */
async function createPairingCode(payload: { childId: string; familyId: string }): Promise<{ code: string; expiresAt: string }> {
  for (let attempt = 0; attempt < PAIR_MAX_ATTEMPTS; attempt++) {
    const code = randomInt(0, 1_000_000).toString().padStart(6, "0");
    if (await setJsonNx(`pair:${code}`, payload, PAIR_TTL_SECONDS)) {
      return { code, expiresAt: new Date(Date.now() + PAIR_TTL_SECONDS * 1000).toISOString() };
    }
  }
  throw new Error("pairing_code_collision");
}

export async function deviceRoutes(app: FastifyInstance) {
  /** Enroll a new device for a child of the authenticated family. */
  app.post("/register", { preHandler: requireParent }, async (req, reply) => {
    const parsed = RegisterSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const user = req.user as AuthedUser;
    const child = await prisma.child.findUnique({
      where: { id: parsed.data.childId },
      include: { family: true },
    });
    if (!child || child.familyId !== user.familyId) {
      return reply.code(403).send({ error: "forbidden" });
    }
    const consent = await checkActiveConsent(child.id, child.family?.region);
    if (!consent.active) {
      return reply.code(428).send({
        error: consent.reason ?? "parental_consent_required",
        ...(consent.jurisdiction ? { jurisdiction: consent.jurisdiction } : {}),
      });
    }
    const { childId, ...rest } = parsed.data;
    const device = await prisma.device.create({ data: { childId, ...rest } });
    return reply.code(201).send({ device });
  });

  /** Create a short-lived 6-digit pairing code binding a child to a future device claim (parent only). */
  app.post("/pair", { preHandler: requireParent }, async (req, reply) => {
    const parsed = PairSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const user = req.user as AuthedUser;
    const child = await prisma.child.findUnique({
      where: { id: parsed.data.childId },
      include: { family: true },
    });
    if (!child || child.familyId !== user.familyId) {
      return reply.code(403).send({ error: "forbidden" });
    }
    const consent = await checkActiveConsent(child.id, child.family?.region);
    if (!consent.active) {
      return reply.code(428).send({
        error: consent.reason ?? "parental_consent_required",
        ...(consent.jurisdiction ? { jurisdiction: consent.jurisdiction } : {}),
      });
    }
    const { code, expiresAt } = await createPairingCode({ childId: child.id, familyId: user.familyId });
    return reply.code(201).send({ code, expiresAt });
  });

  /** Claim a pairing code (no auth: runs before any credentials exist) and mint a device JWT. */
  app.post("/pair/claim", async (req, reply) => {
    const parsed = ClaimSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const key = `pair:${parsed.data.code}`;
    // Consume the code atomically (Redis 5.0 has no GETDEL): Lua GET+DEL in one script, so
    // concurrent claims of the same code cannot both succeed.
    const raw = (await getRedis().eval(
      "local v = redis.call('GET', KEYS[1]); if v then redis.call('DEL', KEYS[1]) end; return v",
      1,
      key,
    )) as string | null;
    const payload = raw ? (JSON.parse(raw) as { childId: string; familyId: string }) : null;
    if (!payload) return reply.code(404).send({ error: "invalid_or_expired_code" });
    const consentCheck = await checkActiveConsent(payload.childId);
    if (!consentCheck.active) {
      return reply.code(428).send({ error: consentCheck.reason ?? "parental_consent_required" });
    }
    const { code: _code, deviceName, ...rest } = parsed.data;
    // NOTE: the Device table is child-scoped (no familyId column); familyId from the Redis
    // payload is used for the JWT claims and response only — never sourced from the client.
    // Handoff item 5: each device gets its OWN internal HMAC secret at claim time, so the
    // global INTERNAL_HMAC_SECRET is never shipped to devices (it remains the ai-engine key).
    const internalSecret = randomBytes(32).toString("hex");
    const device = await prisma.device.create({
      data: {
        ...rest,
        model: deviceName ?? parsed.data.model,
        childId: payload.childId,
        status: "online",
        lastSeen: new Date(),
        internalSecret,
      },
    });
    const token = app.jwt.sign(
      { sub: device.id, deviceId: device.id, childId: payload.childId, familyId: payload.familyId, role: "device" },
      { expiresIn: "10y" },
    );
    return reply.code(201).send({
      device,
      token,
      childId: payload.childId,
      familyId: payload.familyId,
      hmacSecret: internalSecret,
    });
  });

  /** List all devices belonging to the authenticated family's children. */
  app.get("/", { preHandler: requireParent }, async (req) => {
    const user = req.user as AuthedUser;
    const devices = await prisma.device.findMany({
      where: { child: { familyId: user.familyId } },
      include: { child: true },
      orderBy: { lastSeen: "desc" },
    });
    return { devices: devices.map(sanitizeDevice) };
  });

  /** Return one device with its latest telemetry payload merged in. */
  // NOTE: there is no telemetry table in the schema; agents POST to /:id/telemetry and the
  // latest payload is kept in Redis under `device:<id>:telemetry`, merged into this response.
  app.get("/:id", { preHandler: requireFamily({ model: "device" }) }, async (req, reply) => {
    const user = req.user as AuthedUser;
    const { id } = req.params as { id: string };
    if (user.role === "device" && user.deviceId !== id) {
      return reply.code(403).send({ error: "forbidden" });
    }
    const device = (req as unknown as { device: { id: string } }).device;
    const telemetry = await getJson(`device:${device.id}:telemetry`);
    return { device: sanitizeDevice(device), telemetry };
  });


  /** Publish a lock/unlock/ring/sos_clear command to the device's Redis command channel and queue. */
  app.post("/:id/command", { preHandler: [requireParent, requireFamily({ model: "device" })] }, async (req, reply) => {
    const parsed = CommandSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const { id } = req.params as { id: string };
    // ADR-0008 §2c: enforcement commands need active consent; safe-direction commands
    // (unlock, resume, sos_clear) must always remain available to the parent.
    if (!SAFE_DIRECTION_COMMANDS.has(parsed.data.command)) {
      const device = (req as unknown as { device: { id: string; childId: string } }).device;
      if (device?.childId && !(await assertProcessingAllowed(device.childId, reply))) return;
    }
    const message = await enqueueDeviceCommand(id, parsed.data.command, parsed.data.payload ?? {});
    return { published: true, ...message };
  });

  /** Drain the device's pending command queue (long-poll-free polling for agents). */
  app.get("/:id/commands", { preHandler: requireFamily({ model: "device" }) }, async (req, reply) => {
    const { id } = req.params as { id: string };
    // ADR-0008 §2b: an agent polling for commands learns from a 428 that monitoring is paused.
    const device = (req as unknown as { device: { id: string; childId: string } }).device;
    if (device?.childId && !(await assertProcessingAllowed(device.childId, reply))) return;
    // Atomic LRANGE+DEL via Lua (review API-6): no command pushed between read and clear can be lost.
    const raw = (await getRedis().eval(
      "local items = redis.call('LRANGE', KEYS[1], 0, -1); redis.call('DEL', KEYS[1]); return items",
      1,
      `device:${id}:command-queue`,
    )) as string[];
    return raw.map((r) => JSON.parse(r) as unknown);
  });

  /** Update the device push token (FCM/APNs registration). */
  // NOTE: tightened to parent-only per the §14.1 role tightening even though §14.1 also lists
  // this route among device-JWT endpoints; FCM-free test agents never register push tokens.
  app.post("/:id/push-token", { preHandler: [requireParent, requireFamily({ model: "device" })] }, async (req, reply) => {
    const parsed = PushTokenSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const { id } = req.params as { id: string };
    const device = await prisma.device.update({
      where: { id },
      data: { pushToken: parsed.data.pushToken },
    });
    return { device };
  });

  /** Store the latest device telemetry payload in Redis (UsageReporter / TelemetryUploader). */
  app.post("/:id/telemetry", { preHandler: requireFamily({ model: "device" }) }, async (req, reply) => {
    const parsed = TelemetrySchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const { id } = req.params as { id: string };
    const device = (req as unknown as { device: { id: string; childId: string } }).device;
    // ADR-0008 §2b: withdrawal of consent stops collection.
    if (device?.childId && !(await assertProcessingAllowed(device.childId, reply))) return;
    await setJson(`device:${id}:telemetry`, { ...parsed.data, receivedAt: new Date().toISOString() }, 86400);

    // Accumulate daily usage per child (Issue #31: delta windows must accumulate, not overwrite)
    if (parsed.data.totalMinutes && parsed.data.totalMinutes > 0 && device?.childId) {
      const today = new Date().toISOString().slice(0, 10);
      const childUsageKey = `usage:child:${device.childId}:${today}`;
      const redis = getRedis();
      await redis.incrby(childUsageKey, parsed.data.totalMinutes);
      await redis.expire(childUsageKey, 86400 * 2);
    }

    // A device that reports telemetry is alive: refresh lastSeen/battery so the
    // parent app shows a meaningful "online" state.
    await prisma.device.update({
      where: { id },
      data: {
        lastSeen: new Date(),
        status: "online",
        ...(parsed.data.batteryPct !== undefined ? { batteryPct: parsed.data.batteryPct } : {}),
      },
    });
    return reply.code(202).send({ accepted: true });
  });

  /** Ingest a batch of activity events (urls, app usage, calls, SMS) from a device agent (#4). */
  app.post("/:id/activity", { preHandler: requireFamily({ model: "device" }) }, async (req, reply) => {
    const parsed = ActivityBatchSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const { id } = req.params as { id: string };
    const device = (req as unknown as { device: { id: string; childId: string } }).device;
    // ADR-0008 §2b: withdrawal of consent stops collection.
    if (device?.childId && !(await assertProcessingAllowed(device.childId, reply))) return;
    // Filter out live-activity heartbeat snapshots from persistent historical log (BUG-002)
    const persistentEvents = parsed.data.events.filter(
      (e) => !(e.type === "app_usage" && (e.payload as Record<string, unknown>)?.live === true),
    );
    if (persistentEvents.length > 0) {
      await prisma.activityEvent.createMany({
        data: persistentEvents.map((e) => ({
          childId: device.childId,
          deviceId: id,
          ts: e.ts ? new Date(e.ts) : new Date(),
          type: e.type,
          payload: e.payload as Prisma.InputJsonValue,
        })),
      });
    }
    // Live activity (#29): broadcast the latest app_usage event of the batch so the
    // parent dashboard's live chip updates without polling.
    const latestAppUsage = [...parsed.data.events].reverse().find((e) => e.type === "app_usage");
    const familyId = (device as { child?: { familyId?: string } }).child?.familyId;
    if (latestAppUsage && familyId) {
      const payload = latestAppUsage.payload as Record<string, unknown>;
      try {
        await publishFamilyEvent(familyId, {
          type: "live_activity",
          payload: {
            childId: device.childId,
            deviceId: id,
            app: payload.app,
            minutesToday: payload.minutes,
            ts: latestAppUsage.ts ?? new Date().toISOString(),
          },
          ts: new Date().toISOString(),
        });
      } catch {
        // Best-effort live update: ingestion must not fail when the realtime bus is down.
      }
    }
    return reply.code(202).send({ accepted: parsed.data.events.length });
  });

  /** Unenroll a device from the family; revokes its long-lived JWT (handoff item 4). */
  app.delete("/:id", { preHandler: [requireParent, requireFamily({ model: "device" })] }, async (req) => {
    const { id } = req.params as { id: string };
    await prisma.device.delete({ where: { id } });
    await getRedis().set(`revoked:device:${id}`, new Date().toISOString());
    return { deleted: true, id };
  });

  // Handoff item 4: device JWTs live 10 years — a revoked (unpaired) device must get 401s.
  // This hook runs before route preHandlers, so it verifies the JWT itself (the decode is
  // cached by @fastify/jwt, so the route's own verification stays cheap).
  app.addHook("preHandler", async (req, reply) => {
    try {
      await req.jwtVerify();
    } catch {
      return; // unauthenticated requests are rejected by the route's own preHandler
    }
    const user = req.user as { role?: string; deviceId?: string } | undefined;
    if (user?.role !== "device" || !user.deviceId) return;
    const revoked = await getRedis().get(`revoked:device:${user.deviceId}`).catch(() => null);
    if (revoked) await reply.code(401).send({ error: "device_revoked" });
  });
}
