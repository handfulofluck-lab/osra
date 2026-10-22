import { randomBytes, randomInt } from "node:crypto";
import type { FastifyInstance } from "fastify";
import type { Prisma } from "@prisma/client";
import { z } from "zod";
import { prisma } from "../db.js";
import { getRedis, getJson, setJson, setJsonNx } from "../redis.js";
import { requireAuth, requireFamily, requireOwnDevice, requireParent, requirePermission, sanitizeDevice } from "../middleware/requireFamily.js";
import { requireConsent } from "../middleware/requireConsent.js";
import { checkActiveConsent, assertProcessingAllowed } from "../lib/consent.js";
import { ackDeviceCommand, claimPendingCommands, enqueueDeviceCommand, enqueueFailedDeviceCommand, listDeviceCommands } from "../lib/deviceCommands.js";
import { LOCATION_GRANT_STATES, locateNowRefusal } from "../lib/locationGrant.js";
import { publishFamilyEvent } from "../realtime/gateway.js";
import { recordActivityUsage, recordDeviceTotal } from "../lib/usageModel.js";

import { DEVICE_TOKEN_TTL_SECONDS } from "../lib/deviceToken.js";
// Re-exported for existing importers/tests; the constant and its contract live in lib/deviceToken.ts.
export { DEVICE_TOKEN_TTL_SECONDS };

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
    // Plan 1.7: a fresh high-accuracy fix on demand, and the parent-side stop for a ring.
    "locate_now",
    "stop_ring",
    // ADR-0031 decision 2.3: the family witness — the child's phone shows an 8-digit code for the
    // parent who is locked out of their second factor. It restricts nothing (safe-direction,
    // ADR-0019/ADR-0031), and the normal producer is `POST /v1/auth/mfa/reset/confirm`, which sends
    // it to every paired device of the family once the mailbox step is confirmed.
    "show_reset_code",
  ]),
  payload: z.record(z.unknown()).optional(),
});

/** Commands that reduce restriction on the child and therefore never require active consent. */
const SAFE_DIRECTION_COMMANDS = new Set(["unlock", "resume", "resume_internet", "sos_clear", "stop_ring", "show_reset_code"]);

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
    // Issue #221 (D1): the agent's own classification of its location grant. Optional so an older
    // agent keeps working (the server then leaves the stored value unknown and queues locate_now).
    locationGrant: z.enum(LOCATION_GRANT_STATES).optional(),
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

/** Five minutes: the most a device clock may legitimately drift ahead of the server (#260). */
const ACTIVITY_CLOCK_SKEW_MS = 5 * 60_000;

/**
 * Seven days: how far back a reported event time is honoured.
 *
 * The floor is not about the clock, it is about retention. `applyRetention` deletes `ActivityEvent` by
 * `ts < now - RETENTION_DAYS` (90 by default), so an unbounded old timestamp is a *deletion request*: a
 * phone with its clock set back six months uploads a call dated six months ago and the next sweep
 * removes it, and a shorter setback sinks it below the parent's recent list (#260 review). Clamping the
 * floor means an honest phone that was offline for more than a week has its older calls placed at the
 * seven-day mark instead — misdated, but kept, and the parent still sees that they happened.
 */
const ACTIVITY_MAX_AGE_MS = 7 * 24 * 60 * 60_000;

/**
 * Issue #260: the time an activity event happened, bounded on both sides.
 *
 * A device used to send no `ts` at all, so the server stamped `new Date()` and a whole batch of calls
 * was dated to the moment of the 5-minute flush. Now the agent sends the row's own time and this keeps
 * it — **except** when the device clock is ahead, which a child can arrange: one call dated a year in
 * the future pinned itself to the top of the parent's list and hid every real call behind it. It is also
 * bounded below at [ACTIVITY_MAX_AGE_MS] — **seven days, not the 90-day retention window** — because
 * retention deletes `ActivityEvent` by `ts`, so an older reported time acts as a deletion request rather
 * than as a timestamp. Between those two bounds the reported time is exact.
 */
function activityEventTs(ts: string | undefined, now: Date = new Date()): Date {
  if (!ts) return now;
  const parsed = new Date(ts);
  const millis = parsed.getTime();
  if (Number.isNaN(millis)) return now;
  const earliest = now.getTime() - ACTIVITY_MAX_AGE_MS;
  const latest = now.getTime() + ACTIVITY_CLOCK_SKEW_MS;
  return new Date(Math.min(Math.max(millis, earliest), latest));
}

/**
 * Roadmap 3.4: the installed-launchable-app inventory contract.
 *
 * The payload is an inventory only — package id, launcher label, system flag — never usage. Icons
 * are deliberately not accepted: they are large (tens of KB per app), the parent picker can render a
 * generic icon from the package today, and an icon column would make a privacy-minimised list heavier
 * for little gain. The device and the server share the same bounds so a buggy agent cannot enlarge
 * the table: 500 apps, 100-character labels, one row per package.
 */
const INSTALLED_APPS_VERSION = 1;
const MAX_INSTALLED_APPS = 500;
const MAX_APP_LABEL_LENGTH = 100;
const APP_PACKAGE_ID = /^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$/;

const InstalledAppSchema = z.object({
  packageId: z.string().trim().min(1).max(255).regex(APP_PACKAGE_ID),
  label: z.string().max(MAX_APP_LABEL_LENGTH),
  isSystem: z.boolean().default(false),
});

const InstalledAppsSchema = z.object({
  version: z.literal(INSTALLED_APPS_VERSION),
  apps: z.array(InstalledAppSchema).max(MAX_INSTALLED_APPS),
});

/** Trim labels, fall back to the package id, and keep the first occurrence of a package (dedupe). */
function normalizeInstalledApps(
  apps: Array<z.infer<typeof InstalledAppSchema>>,
): Array<{ packageId: string; label: string; isSystem: boolean }> {
  const seen = new Map<string, { packageId: string; label: string; isSystem: boolean }>();
  for (const app of apps) {
    if (seen.has(app.packageId)) continue;
    seen.set(app.packageId, {
      packageId: app.packageId,
      label: app.label.trim() || app.packageId,
      isSystem: app.isSystem,
    });
  }
  return [...seen.values()];
}

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
  /**
   * Enroll a new device for a child of the authenticated family.
   * Issue #138: enrollment issues device credentials, so it sits inside the `devices` permission
   * surface (ADR-0014, amendment 2026-10-18) — the same gate as command, push-token and unpair.
   * The response is sanitized: `internalSecret` (minted at pair/claim) and `pushToken` must never
   * leave the API through the parent-facing enrollment route.
   */
  app.post("/register", { preHandler: [requireParent, requirePermission("devices")] }, async (req, reply) => {
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
    return reply.code(201).send({ device: sanitizeDevice(device) });
  });

  /**
   * Create a short-lived 6-digit pairing code binding a child to a future device claim.
   * Issue #138: a code is redeemed by the unauthenticated `/pair/claim` for a device JWT and a
   * per-device HMAC secret, so minting one is a `devices`-permission action (ADR-0014 amendment).
   */
  app.post("/pair", { preHandler: [requireParent, requirePermission("devices")] }, async (req, reply) => {
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

  /**
   * Roadmap 3.4: the parent-facing view of a device's installed-launchable-app inventory, used by
   * the Rules editor picker. It is family-scoped like every device route, and it names the `rules`
   * permission because the payload is exactly what a parent needs to shape an app rule (a co-parent
   * admitted only for `alerts` has no business enumerating the child's apps). Reads elsewhere are
   * family-scoped; this one is also permission-gated on purpose — the inventory is more revealing
   * than device metadata, and gating it cannot break a legitimate rules editor.
   *
   * `version` is the contract version (1), not the per-device report version: an old report still
   * answers with the shape a current parent app understands. `reportedAt` is null until the agent
   * has checked in once.
   */
  app.get("/:id/apps", { preHandler: [requireParent, requirePermission("rules"), requireFamily({ model: "device" })] }, async (req) => {
    const { id } = req.params as { id: string };
    const device = (req as unknown as { device: { appsReportedAt?: Date | null } }).device;
    const apps = await prisma.deviceApp.findMany({
      where: { deviceId: id },
      select: { packageId: true, label: true, isSystem: true },
      orderBy: [{ label: "asc" }, { packageId: "asc" }],
    });
    return {
      deviceId: id,
      version: INSTALLED_APPS_VERSION,
      reportedAt: device?.appsReportedAt ? new Date(device.appsReportedAt).toISOString() : null,
      count: apps.length,
      apps,
    };
  });

  /**
   * Roadmap 3.4: replace a device's installed-launchable-app inventory.
   *
   * Agent write composed exactly like `/telemetry` and `/activity`: `requireFamily` proves the
   * device belongs to the caller's family and `requireOwnDevice` proves the caller *is* that device,
   * so device A cannot write sibling B (parent tokens stay family-scoped). Device-JWT auth, not the
   * `/internal` HMAC contract — this is an agent surface route, and the HMAC helper is for service
   * and alert writes. Consent withdrawal stops the upload (`assertProcessingAllowed`, 428).
   *
   * The write is a replace, not a merge: a package uninstalled on the phone disappears, and an empty
   * list clears the inventory. That is the honest model for "what is installed now"; a merge would
   * accumulate ghosts forever.
   */
  app.post("/:id/apps", { preHandler: [requireFamily({ model: "device" }), requireOwnDevice()] }, async (req, reply) => {
    const { id } = req.params as { id: string };
    const parsed = InstalledAppsSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const device = (req as unknown as { device: { id: string; childId: string } }).device;
    if (device?.childId && !(await assertProcessingAllowed(device.childId, reply))) return;

    const apps = normalizeInstalledApps(parsed.data.apps);
    const reportedAt = new Date();
    const ops: Prisma.PrismaPromise<unknown>[] = [
      prisma.deviceApp.deleteMany({ where: { deviceId: id } }),
      prisma.device.update({
        where: { id },
        data: { lastSeen: reportedAt, status: "online", appsReportedAt: reportedAt, appsVersion: parsed.data.version },
      }),
    ];
    if (apps.length > 0) {
      ops.splice(1, 0, prisma.deviceApp.createMany({ data: apps.map((app) => ({ deviceId: id, ...app })) }));
    }
    await prisma.$transaction(ops);
    return reply.code(202).send({ accepted: true, count: apps.length, version: parsed.data.version });
  });

  /** Publish a lock/unlock/ring/sos_clear command to the device's Redis command channel and queue. */
  app.post("/:id/command", { preHandler: [requireParent, requirePermission("devices"), requireFamily({ model: "device" })] }, async (req, reply) => {
    const parsed = CommandSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const { id } = req.params as { id: string };
    const user = req.user as AuthedUser & { sub: string };
    const device = (req as unknown as {
      device: { id: string; childId: string; locationGrant?: string | null; locationGrantReportedAt?: Date | string | null };
    }).device;
    // ADR-0008 §2c: enforcement commands need active consent; safe-direction commands
    // (unlock, resume, sos_clear) must always remain available to the parent.
    if (!SAFE_DIRECTION_COMMANDS.has(parsed.data.command)) {
      if (device?.childId && !(await assertProcessingAllowed(device.childId, reply))) return;
    }
    // Issue #221 (D1): a `locate_now` the last telemetry says the phone cannot answer is not queued
    // for a WorkManager tick it would miss. It is recorded `failed` at once with the same reason
    // vocabulary the agent acks (#132), and the device is not woken: no round trip is attempted.
    // The report must also be FRESH: refusing on a stale grant tells a parent to fix something the
    // child already fixed, so an old or undated report queues and lets the phone answer.
    if (parsed.data.command === "locate_now") {
      const reason = locateNowRefusal(device?.locationGrant, device?.locationGrantReportedAt);
      if (reason) {
        const failed = await enqueueFailedDeviceCommand(id, "locate_now", reason, { requestedBy: user.sub });
        return { published: false, status: "failed", reason, ...failed };
      }
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
  // Audit finding 6: `requirePermission("devices")` matches the other parent-side device mutations
  // (command, unpair) — a co-parent admitted without the `devices` tag may not repoint a child's
  // notifications. The response is an explicit allowlist (`select`) and then `sanitizeDevice`, so the
  // per-device HMAC secret and the push token cannot leave the server, and a future secret column is
  // not returned just because it exists.
  app.post("/:id/push-token", { preHandler: [requireParent, requirePermission("devices"), requireFamily({ model: "device" })] }, async (req, reply) => {
    const parsed = PushTokenSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const { id } = req.params as { id: string };
    const device = await prisma.device.update({
      where: { id },
      data: { pushToken: parsed.data.pushToken },
      select: { id: true, childId: true, platform: true, model: true, osVersion: true, status: true, batteryPct: true, lastSeen: true },
    });
    return { device: sanitizeDevice(device) };
  });

  /** Store the latest device telemetry payload in Redis (UsageReporter / TelemetryUploader). */
  // Audit finding 5: `requireOwnDevice` closes the family-scoping gap — device A used to be able to
  // post telemetry for sibling B (refreshing B's lastSeen, battery and day totals). Parent tokens
  // stay family-scoped, and the shared preHandler means a future agent-write route composes it too.
  app.post("/:id/telemetry", { preHandler: [requireFamily({ model: "device" }), requireOwnDevice()] }, async (req, reply) => {
    const { id } = req.params as { id: string };
    const parsed = TelemetrySchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
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
      // Phase 2c: the same delta into the durable day total, so "today" survives a Redis flush.
      try {
        await recordDeviceTotal(device.childId, id, parsed.data.totalMinutes);
      } catch (err) {
        req.log.warn({ err }, "usage rollup write failed (telemetry)");
      }
    }

    // A device that reports telemetry is alive: refresh lastSeen/battery so the
    // parent app shows a meaningful "online" state.
    await prisma.device.update({
      where: { id },
      data: {
        lastSeen: new Date(),
        status: "online",
        ...(parsed.data.batteryPct !== undefined ? { batteryPct: parsed.data.batteryPct } : {}),
        // Issue #221 (D1): the latest grant report wins; omitting the field leaves the stored value
        // untouched (an old agent does not erase what a newer one reported). The report is timestamped
        // so the command route can tell a fresh grant from a stale one (a refusal on a stale report
        // tells the parent to fix something the child already fixed).
        ...(parsed.data.locationGrant !== undefined
          ? { locationGrant: parsed.data.locationGrant, locationGrantReportedAt: new Date() }
          : {}),
      },
    });
    return reply.code(202).send({ accepted: true });
  });

  /** Ingest a batch of activity events (urls, app usage, calls, SMS) from a device agent (#4). */
  // Same `requireOwnDevice` rule as /telemetry: device tokens write only their own row.
  app.post("/:id/activity", { preHandler: [requireFamily({ model: "device" }), requireOwnDevice()] }, async (req, reply) => {
    const { id } = req.params as { id: string };
    const parsed = ActivityBatchSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
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
          ts: activityEventTs(e.ts),
          type: e.type,
          payload: e.payload as Prisma.InputJsonValue,
        })),
      });
      // Phase 2c: fold the batch into AppUsageDaily / WebVisit. A failure here must not reject the
      // batch (the raw log is the source of truth; the nightly rollup reconciles from it).
      try {
        await recordActivityUsage(device.childId, id, persistentEvents as Array<{ ts?: string; type: string; payload: Record<string, unknown> }>);
      } catch (err) {
        req.log.warn({ err }, "usage rollup write failed (activity)");
      }
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
  app.delete("/:id", { preHandler: [requireParent, requirePermission("devices"), requireFamily({ model: "device" })] }, async (req) => {
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
