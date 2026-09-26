import { getRedis, publishJson } from "../redis.js";

export interface DeviceCommand {
  deviceId: string;
  type: string;
  payload: Record<string, unknown>;
  ts: string;
}

/** Publish a {type, payload} command to a device's Redis channel and its polling queue. */
export async function enqueueDeviceCommand(
  deviceId: string,
  type: string,
  payload: Record<string, unknown> = {},
): Promise<DeviceCommand> {
  // Shape matches the agent contract: { type, payload } (extra fields ignored by clients).
  const message: DeviceCommand = { deviceId, type, payload, ts: new Date().toISOString() };
  await publishJson(`device:${deviceId}:commands`, message);
  // Also queue for HTTP-polling agents (desktop agent); consumed by GET /:id/commands.
  const redis = getRedis();
  await redis.lpush(`device:${deviceId}:command-queue`, JSON.stringify(message));
  await redis.ltrim(`device:${deviceId}:command-queue`, 0, 99);
  return message;
}
