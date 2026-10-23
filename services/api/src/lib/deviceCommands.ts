import type { Prisma } from "@prisma/client";
import { prisma } from "../db.js";
import { publishJson } from "../redis.js";
import { wakeDeviceDetached } from "./push/notify.js";

/**
 * Durable device command queue (Phase 2b, ADR-0012).
 *
 * Before: a command was an LPUSH onto a Redis list capped at 100 and a pub/sub message. A Redis
 * restart dropped pending locks, nothing recorded delivery, and the parent app said "reaches the
 * device within ~1 minute" with nothing behind it.
 *
 * Now: every command is a `DeviceCommand` row. The device's drain atomically claims pending rows
 * (`pending → delivered`), an ack-capable agent reports `acked`/`failed`, and rows that were never
 * claimed before `expiresAt` become `expired`. Redis pub/sub is kept purely as the wake-up signal
 * for agents holding a socket; the list is gone.
 */

export type CommandStatus = "pending" | "delivered" | "acked" | "failed" | "expired";

/** The wire shape agents receive. `type` and `payload` are the original contract; the rest is additive. */
export interface DeviceCommandMessage {
  id: string;
  deviceId: string;
  type: string;
  payload: Record<string, unknown>;
  ts: string;
  expiresAt: string;
  attempt: number;
}

/** How long a command stays claimable. Ringing a phone an hour late is worse than not ringing it. */
export const COMMAND_TTL_SECONDS: Record<string, number> = {
  ring: 10 * 60,
  stop_ring: 10 * 60,
  // Issue #221 (D1): a phone without the background location grant is polled only by WorkManager,
  // which Android clamps to a 15-minute floor plus its 5-minute flex. 10 minutes could expire
  // before the single remaining poll ran; 20 covers the worst-case gap between two ticks.
  locate_now: 20 * 60,
  sos_clear: 60 * 60,
  // ADR-0031: the row carries the plaintext 8-digit code, so the row's life is the code's life (10
  // minutes). The expiry sweep clears the payload when it ends (src/jobs/mfaResetExpiry.ts).
  show_reset_code: 10 * 60,
  rules_updated: 24 * 3600,
  consent_granted: 7 * 24 * 3600,
  consent_revoked: 7 * 24 * 3600,
};
export const DEFAULT_COMMAND_TTL_SECONDS = 24 * 3600;

/** Delivered-but-unacked commands are offered again to ack-capable agents after this long. */
export const REDELIVER_AFTER_SECONDS = 120;
export const MAX_ATTEMPTS = 3;

/** Commands for which a second pending copy adds nothing; the existing pending row is returned instead. */
const COALESCED_TYPES = new Set(["rules_updated"]);

export function ttlFor(type: string): number {
  return COMMAND_TTL_SECONDS[type] ?? DEFAULT_COMMAND_TTL_SECONDS;
}

type Row = {
  id: string;
  deviceId: string;
  type: string;
  payload: unknown;
  status: string;
  createdAt: Date;
  expiresAt: Date;
  attempts: number;
};

export function toMessage(row: Row): DeviceCommandMessage {
  return {
    id: row.id,
    deviceId: row.deviceId,
    type: row.type,
    payload: (row.payload ?? {}) as Record<string, unknown>,
    ts: row.createdAt.toISOString(),
    expiresAt: row.expiresAt.toISOString(),
    attempt: row.attempts,
  };
}

export interface EnqueueOptions {
  /** Parent id, or "system" for server-originated commands. */
  requestedBy?: string;
  ttlSeconds?: number;
}

/** Persist a command for a device, then wake any connected agent over Redis pub/sub. */
export async function enqueueDeviceCommand(
  deviceId: string,
  type: string,
  payload: Record<string, unknown> = {},
  opts: EnqueueOptions = {},
): Promise<DeviceCommandMessage> {
  if (COALESCED_TYPES.has(type)) {
    const existing = await prisma.deviceCommand.findFirst({
      where: { deviceId, type, status: "pending", expiresAt: { gt: new Date() } },
    });
    if (existing) return toMessage(existing);
  }
  const ttl = opts.ttlSeconds ?? ttlFor(type);
  const row = await prisma.deviceCommand.create({
    data: {
      deviceId,
      type,
      payload: payload as Prisma.InputJsonValue,
      requestedBy: opts.requestedBy ?? "system",
      expiresAt: new Date(Date.now() + ttl * 1000),
    },
  });
  const message = toMessage(row);
  // Wake-up only: an agent that misses this still finds the row on its next drain.
  await publishJson(`device:${deviceId}:commands`, message).catch(() => undefined);
  // #319: the same wake over FCM, so a backgrounded phone with no socket does not wait for the
  // 15-minute poll. Detached on purpose — a slow or failed Google round trip must never delay or
  // fail a parent's command, and the row above is already durable. One funnel: every command
  // producer (controls, rules, auth, this file) reaches the device through here.
  wakeDeviceDetached(deviceId);
  return message;
}

/**
 * Record a command the server already knows cannot run, without queueing or waking the device.
 *
 * Issue #221 (D1): `locate_now` against a handset whose last telemetry says the background location
 * grant is missing would otherwise sit `pending` until the next 15-minute WorkManager tick and then
 * turn `expired` without ever reaching the phone. The row is born `failed` with the reason in
 * `result`, so `/commands/history` and the POST response tell the parent immediately. There is
 * deliberately no Redis publish: no device round trip is attempted.
 */
export async function enqueueFailedDeviceCommand(
  deviceId: string,
  type: string,
  reason: string,
  opts: EnqueueOptions = {},
): Promise<DeviceCommandMessage> {
  const now = new Date();
  const ttl = opts.ttlSeconds ?? ttlFor(type);
  const row = await prisma.deviceCommand.create({
    data: {
      deviceId,
      type,
      payload: {},
      requestedBy: opts.requestedBy ?? "system",
      status: "failed",
      ackedAt: now,
      result: { reason } as Prisma.InputJsonValue,
      expiresAt: new Date(now.getTime() + ttl * 1000),
    },
  });
  return toMessage(row);
}

/**
 * Atomically claim everything the device should act on now, oldest first:
 *  - every `pending` row that has not expired (→ `delivered`, attempts+1);
 *  - for ack-capable agents only, `delivered` rows older than `REDELIVER_AFTER_SECONDS` that were
 *    never acked, up to `MAX_ATTEMPTS` (a crash between drain and action must not lose a lock).
 * Expired `pending` rows are marked `expired` on the way through so history tells the truth.
 * Single statements with RETURNING, so two concurrent drains never hand out the same row twice.
 */
export async function claimPendingCommands(deviceId: string, opts: { ackCapable?: boolean } = {}): Promise<DeviceCommandMessage[]> {
  // Issue #53: never use the server's NOW() here. The first version compared a naive TIMESTAMP(3)
  // column to NOW() (timestamptz); on a non-UTC session (the testers' Asia/Dubai hosts) Postgres
  // read the naive UTC value as local wall-clock and every fresh command was already "expired",
  // so ring/lock/unlock never reached a device. Columns are now timestamptz (migration 0012) AND
  // the instant is bound from JS, so the comparison is independent of the session time zone.
  const now = new Date();
  await prisma.$executeRaw`
    UPDATE "DeviceCommand" SET "status" = 'expired'
    WHERE "deviceId" = ${deviceId} AND "status" = 'pending' AND "expiresAt" <= ${now}`;
  const redeliverCutoff = new Date(now.getTime() - REDELIVER_AFTER_SECONDS * 1000);
  const rows = opts.ackCapable
    ? await prisma.$queryRaw<Row[]>`
        UPDATE "DeviceCommand"
        SET "status" = 'delivered', "deliveredAt" = ${now}, "attempts" = "attempts" + 1
        WHERE "deviceId" = ${deviceId} AND "expiresAt" > ${now} AND (
          "status" = 'pending'
          OR ("status" = 'delivered' AND "ackedAt" IS NULL AND "deliveredAt" < ${redeliverCutoff} AND "attempts" < ${MAX_ATTEMPTS})
        )
        RETURNING "id", "deviceId", "type", "payload", "status", "createdAt", "expiresAt", "attempts"`
    : await prisma.$queryRaw<Row[]>`
        UPDATE "DeviceCommand"
        SET "status" = 'delivered', "deliveredAt" = ${now}, "attempts" = "attempts" + 1
        WHERE "deviceId" = ${deviceId} AND "expiresAt" > ${now} AND "status" = 'pending'
        RETURNING "id", "deviceId", "type", "payload", "status", "createdAt", "expiresAt", "attempts"`;
  return rows
    .sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime())
    .map(toMessage);
}

/** Device reports the outcome of a delivered command. Returns null when no such delivered row exists. */
export async function ackDeviceCommand(
  deviceId: string,
  commandId: string,
  outcome: "ok" | "failed",
  detail?: Record<string, unknown>,
) {
  const result = await prisma.deviceCommand.updateMany({
    where: { id: commandId, deviceId, status: "delivered" },
    data: {
      status: outcome === "ok" ? "acked" : "failed",
      ackedAt: new Date(),
      result: (detail ?? {}) as Prisma.InputJsonValue,
    },
  });
  if (result.count === 0) return null;
  // ADR-0031 claim 6: a `show_reset_code` row holds the plaintext 8-digit code, and the acknowledgement
  // is one of the two moments it must stop existing (the other is expiry, swept by the job). Clearing
  // is unconditional on the outcome and leaves the status/ack fields above untouched.
  await prisma.deviceCommand.updateMany({ where: { id: commandId, type: "show_reset_code" }, data: { payload: {} } });
  return prisma.deviceCommand.findUnique({ where: { id: commandId } });
}

/**
 * Command types whose payload is a credential and which no parent surface may read back.
 *
 * #305 review (Claude): `GET /v1/devices/:id/commands/history` returned the plaintext 8-digit
 * `show_reset_code`, so any family parent — the guardian, or the parent being reset — could read the
 * witness code straight out of the history and the whole step proved nothing. He demonstrated it by
 * passing the witness live with a code a guardian read. The payload is a device credential: the API
 * writes it, the child's phone displays it, and the parent-facing view shows only that the command
 * existed.
 */
const DEVICE_ONLY_PAYLOAD_TYPES = new Set(["show_reset_code"]);

/** Parent-facing, non-destructive view: newest first, with status so the UI can say delivered/pending/failed. */
export async function listDeviceCommands(deviceId: string, limit = 20) {
  const rows = await prisma.deviceCommand.findMany({
    where: { deviceId },
    orderBy: { createdAt: "desc" },
    take: Math.min(Math.max(limit, 1), 100),
  });
  const now = Date.now();
  // Report expiry even before a drain has swept the row.
  return rows.map((r) => ({
    ...r,
    // The row still proves the command was queued and what happened to it; the payload does not travel.
    payload: DEVICE_ONLY_PAYLOAD_TYPES.has(r.type) ? {} : r.payload,
    status: r.status === "pending" && r.expiresAt.getTime() <= now ? "expired" : r.status,
  }));
}
