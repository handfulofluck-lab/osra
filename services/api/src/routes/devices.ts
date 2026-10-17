import { randomBytes, randomInt } from "node:crypto";
import type { FastifyInstance } from "fastify";
import type { Prisma } from "@prisma/client";
import { z } from "zod";
import { prisma } from "../db.js";
import { getRedis, getJson, setJson, setJsonNx } from "../redis.js";
import { requireAuth, requireFamily, requireParent, sanitizeDevice } from "../middleware/requireFamily.js";
import { requireConsent } from "../middleware/requireConsent.js";
import { checkActiveConsent, assertProcessingAllowed } from "../lib/consent.js";
import { ackDeviceCommand, claimPendingCommands, enqueueDeviceCommand, listDeviceCommands } from "../lib/deviceCommands.js";
import { publishFamilyEvent } from "../realtime/gateway.js";

/**
 * Device JWT lifetime (10 years, `ms`-style "10y" = 365.25-day years), in seconds. The SAME constant
 * bounds the `revoked:device:<id>` key written on unpair (#56): that key is what turns a still-valid
 * device token into `401 device_revoked` once the `Device` row is gone, so it must outlive any token
 * the device could present — never shorter than this, never reaped by cleanup. A key written at
 * unpair with this TTL expires no earlier than the last token minted before the unpair.
 */
export const DEVICE_TOKEN_TTL_SECONDS = Math.round(10 * 365.25 * 24 * 60 * 60); // 315 576 000

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

const AckSchema = z.object({
  status: z.enum(["ok", "failed"]),
  detail: z.record(z.unknown()).optional(),
});

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
      { expiresIn: DEVICE_TOKEN_TTL_SECONDS },
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
    const user = req.user as AuthedUser & { sub: string };
    // ADR-0008 §2c: enforcement commands need active consent; safe-direction commands
    // (unlock, resume, sos_clear) must always remain available to the parent.
    if (!SAFE_DIRECTION_COMMANDS.has(parsed.data.command)) {
      const device = (req as unknown as { device: { id: string; childId: string } }).device;
      if (device?.childId && !(await assertProcessingAllowed(device.childId, reply))) return;
    }
    // Phase 2b: the command is a durable row; the response carries its id so the parent app can
    // poll /commands/history for delivered / acked / failed instead of guessing.
    const message = await enqueueDeviceCommand(id, parsed.data.command, parsed.data.payload ?? {}, { requestedBy: user.sub });
    return { published: true, status: "pending", ...message };
  });
  /**
   * Agent drain (Phase 2b). Device JWT only — a parent token used to be able to consume the queue
   * (probe note B11); parents read `/commands/history` instead. `?ack=1` declares an ack-capable
   * agent: its delivered-but-unacked commands are re-offered after 120 s, up to 3 attempts.
   * Shape is unchanged for existing agents: an array of `{type, payload, ...}`.
   */
  app.get("/:id/commands", { preHandler: requireFamily({ model: "device" }) }, async (req, reply) => {
    const { id } = req.params as { id: string };
    const user = req.user as { role?: string; deviceId?: string; sub?: string };
    if (user.role !== "device") return reply.code(403).send({ error: "device_role_required", hint: "parents: GET /v1/devices/:id/commands/history" });
    if ((user.deviceId ?? user.sub) !== id) return reply.code(403).send({ error: "forbidden" });
    // ADR-0008 §2b: an agent polling for commands learns from a 428 that monitoring is paused.
    const device = (req as unknown as { device: { id: string; childId: string } }).device;
    if (device?.childId && !(await assertProcessingAllowed(device.childId, reply))) return;
    const ackCapable = (req.query as { ack?: string })?.ack === "1";
    return claimPendingCommands(id, { ackCapable });
  });

  /** Agent reports the outcome of a delivered command (Phase 2b). */
  app.post("/:id/commands/:commandId/ack", { preHandler: requireFamily({ model: "device" }) }, async (req, reply) => {
    const { id, commandId } = req.params as { id: string; commandId: string };
    const user = req.user as { role?: string; deviceId?: string; sub?: string };
    if (user.role !== "device" || (user.deviceId ?? user.sub) !== id) return reply.code(403).send({ error: "forbidden" });
    const parsed = AckSchema.safeParse(req.body ?? {});
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const row = await ackDeviceCommand(id, commandId, parsed.data.status, parsed.data.detail);
    if (!row) return reply.code(404).send({ error: "no_delivered_command" });
    return { command: row };
  });

  /** Parent view of recent commands and their delivery state (Phase 2b). Never consumes anything. */
  app.get("/:id/commands/history", { preHandler: [requireParent, requireFamily({ model: "device" })] }, async (req) => {
    const { id } = req.params as { id: string };
    const limit = Number((req.query as { limit?: string })?.limit ?? 20);
    const items = await listDeviceCommands(id, Number.isFinite(limit) ? limit : 20);
    return { items };
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
    // Security state, not residue (#56): once the row is gone this key is the only thing that makes
    // the device's 10-year JWT answer 401 (server.ts preHandler, location.ts, gateway.ts, and the
    // hook below). It is bounded by the token lifetime so an unpaired device cannot leave a key
    // forever, and it must never be given a shorter TTL or deleted while that token could still be
    // presented — `scripts/cleanup-test-redis.mjs` deliberately keeps it.
    await getRedis().set(`revoked:device:${id}`, new Date().toISOString(), "EX", DEVICE_TOKEN_TTL_SECONDS);
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
