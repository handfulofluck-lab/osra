import { randomUUID } from "node:crypto";
import { z } from "zod";
import { prisma } from "../db.js";
import { toMessage, ttlFor, wakeForDeviceCommand } from "./deviceCommands.js";

const targetsSchema = z.array(z.object({
  deviceId: z.string(),
  commandId: z.string(),
}));

function internetCommandType(paused: boolean): string {
  return paused ? "pause_internet" : "resume_internet";
}

/**
 * Persist the child-wide request and its exact target commands together.
 * The existing child row also serializes requests when there is no prior operation.
 */
/** `byName`: the acting adult's server-stamped display name for the child's C-04 feed (#1179), if any. */
export async function requestChildInternet(childId: string, paused: boolean, byName?: string): Promise<boolean> {
  const type = internetCommandType(paused);
  const commands = await prisma.$transaction(async (tx) => {
    const [child] = await tx.$queryRaw<{ id: string }[]>`
      SELECT id FROM "Child" WHERE id = ${childId} FOR UPDATE
    `;
    if (!child) return null;

    const previous = await tx.childInternetOperation.findUnique({ where: { childId } });
    const generation = (previous?.generation ?? 0) + 1;
    const timestamp = Math.max(Date.now(), (previous?.requestedAt.getTime() ?? 0) + 1);
    const requestedAt = new Date(timestamp);
    const expiresAt = new Date(timestamp + ttlFor(type) * 1000);
    const devices = await tx.device.findMany({ where: { childId, pairedAt: { not: null } }, select: { id: true } });
    const rows = devices.length === 0 ? [] : await tx.deviceCommand.createManyAndReturn({
      data: devices.map(({ id: deviceId }) => ({
        deviceId,
        type,
        payload: byName ? { byName } : {},
        requestedBy: "system",
        createdAt: requestedAt,
        expiresAt,
      })),
    });
    const operation = {
      id: randomUUID(),
      generation,
      desiredPaused: paused,
      requestedAt,
      targets: rows.map(({ deviceId, id: commandId }) => ({ deviceId, commandId })),
    };
    await tx.childInternetOperation.upsert({
      where: { childId },
      create: { childId, ...operation },
      update: operation,
    });
    return rows;
  });
  if (commands === null) return false;
  for (const row of commands) void wakeForDeviceCommand(toMessage(row)).catch(() => undefined);
  return true;
}

/**
 * Acknowledgements are receipts for this request. They do not measure current connectivity.
 */
export async function latestChildInternet(childId: string) {
  const operation = await prisma.childInternetOperation.findUnique({ where: { childId } });
  if (!operation) return null;

  const targets = targetsSchema.safeParse(operation.targets);
  const targetIds = new Map((targets.success ? targets.data : []).map(({ deviceId, commandId }) =>
    [deviceId, commandId] as const));
  const type = internetCommandType(operation.desiredPaused);
  const [devices, commands] = await Promise.all([
    prisma.device.findMany({ where: { childId, pairedAt: { not: null } }, select: { id: true } }),
    targetIds.size === 0 ? [] : prisma.deviceCommand.findMany({
      where: {
        id: { in: [...targetIds.values()] },
        type,
        device: { childId, pairedAt: { not: null } },
      },
      select: { id: true, deviceId: true, type: true, status: true, expiresAt: true },
    }),
  ]);
  const deviceIds = new Set([...targetIds.keys(), ...devices.map(({ id }) => id)]);
  const connectedIds = new Set(devices.map(({ id }) => id));
  const byId = new Map(commands.map((command) => [command.id, command]));
  const now = Date.now();
  return {
    paused: operation.desiredPaused,
    internetRequest: {
      id: operation.id,
      generation: operation.generation,
      action: operation.desiredPaused ? "pause" : "resume",
      requestedAt: operation.requestedAt.toISOString(),
      devices: [...deviceIds].map((deviceId) => {
        const commandId = targetIds.get(deviceId) ?? null;
        const command = commandId && connectedIds.has(deviceId) ? byId.get(commandId) : undefined;
        if (!command || command.deviceId !== deviceId || command.type !== type) {
          return { deviceId, commandId, status: "unknown" };
        }
        const expired = command.expiresAt.getTime() <= now;
        const status = command.status === "pending" && expired ? "expired"
          : command.status === "delivered" && expired ? "unconfirmed"
          : command.status;
        return { deviceId, commandId, status };
      }),
    },
  };
}
